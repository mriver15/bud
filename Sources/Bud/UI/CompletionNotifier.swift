import AppKit
import UserNotifications

/// Says so when a long turn finishes while Bud is not what you are looking at.
///
/// A two-second answer is not worth a banner — it arrived while you were still
/// watching. A turn that ran for a minute after you moved on is the case where
/// silence is indistinguishable from nothing having happened, and it is the whole
/// reason this exists. So the delay is the gate: short turns say nothing at all.
@MainActor
final class CompletionNotifier {
    /// Below this, the answer landed while the window was still in front of you.
    private static let minimumDuration: TimeInterval = 6

    private var startedAt: Date?

    /// Whether notifications are worth attempting at all.
    ///
    /// `UNUserNotificationCenter.current()` traps in a process with no bundle —
    /// which is every command-line mode this app has, including the verification
    /// runs that drive real turns. A crash there would take the whole suite down.
    private static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    func turnStarted() {
        guard Self.isBundled else { return }
        startedAt = Date()
    }

    /// Forgets an in-flight turn without reporting it. Stopping is not finishing,
    /// and being told about an answer somebody deliberately interrupted is worse
    /// than being told nothing.
    func turnCancelled() {
        startedAt = nil
    }

    func turnFinished(summary: String) {
        defer { startedAt = nil }
        guard Self.isBundled, let startedAt else { return }
        guard Date().timeIntervalSince(startedAt) >= Self.minimumDuration else { return }
        // Frontmost with the window up means the answer is already on screen, and
        // a banner about something you can see is noise.
        guard !NSApp.isActive || !isWindowVisible else { return }
        deliver(summary)
    }

    private var isWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.level == .normal }
    }

    private func deliver(_ summary: String) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                await Self.post(summary, via: center)

            case .notDetermined:
                // Asked here rather than at launch: the first time it can be
                // explained by the thing it is for.
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    await Self.post(summary, via: center)
                } else {
                    bounce()
                }

            default:
                // Refused, or unavailable. The Dock icon needs no permission and
                // is already what a Mac reads as "something finished".
                bounce()
            }
        }
    }

    private func bounce() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    private static func post(_ body: String, via center: UNUserNotificationCenter) async {
        let content = UNMutableNotificationContent()
        content.title = "Bud"
        content.body = body
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }
}
