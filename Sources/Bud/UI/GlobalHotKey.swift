import AppKit
import Carbon.HIToolbox

/// A summon-anywhere shortcut, registered through Carbon.
///
/// `RegisterEventHotKey` is used rather than `NSEvent.addGlobalMonitorForEvents`
/// because the latter requires the Accessibility permission, which would put a
/// scary system prompt in front of a first launch. Carbon hotkeys need no such
/// grant and survive the app being in the background.
/// `@unchecked Sendable`: the two Carbon refs are written once during `init` and
/// only read again in `deinit`, and the callback is an immutable `@MainActor`
/// closure. There is no mutable state that can be observed from two threads, so
/// the compiler's blanket rejection of the class is stricter than the reality.
final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: @MainActor () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `UInt32(kVK_ANSI_B)`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | optionKey)`.
    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping @MainActor () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4255_4431), id: 1) // 'BUD1'
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    fileprivate func fire() {
        let callback = self.callback
        // The Carbon handler is not isolated; the shortcut itself must run on the
        // main actor. Hopping here rather than assuming keeps this correct even
        // if the handler is ever invoked off the main thread.
        Task { @MainActor in callback() }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

private func globalHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    // Carbon delivers hot keys on the main thread in practice, but the callback
    // is not isolated, so the reference is only dereferenced inside the
    // main-actor task. The raw pointer is carried across as an integer because
    // `UnsafeMutableRawPointer` is not `Sendable`; the address is just a number,
    // and the object it names never leaves the main actor.
    //
    // The pointer is unretained, which is safe because the owner keeps the hot
    // key alive for the process lifetime and removes this handler before release.
    let address = UInt(bitPattern: userData)
    Task { @MainActor in
        guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<GlobalHotKey>.fromOpaque(raw).takeUnretainedValue().fire()
    }
    return noErr
}

extension GlobalHotKey {
    /// The default summon shortcut: ⌥⌘B.
    static func summon(callback: @escaping @MainActor () -> Void) -> GlobalHotKey? {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(optionKey | cmdKey),
            callback: callback
        )
    }

    static var summonShortcutLabel: String { "⌥⌘B" }
}
