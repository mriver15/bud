import Foundation
import Security

/// Read/write access to Bud's secrets in the macOS Keychain.
///
/// A protocol rather than a concrete type so the migration logic can be
/// exercised against an in-memory fake and never has to reach the real
/// Keychain in a test. Every item is a generic password keyed by `account`,
/// all filed under the one `service` (the bundle identifier).
public protocol KeychainStoring: Sendable {
    /// The value for `account`, or nil when it is absent or unreadable.
    func get(_ account: String) -> String?
    /// Stores `value` for `account`, overwriting any previous value. Returns
    /// whether the write landed.
    @discardableResult
    func set(_ account: String, value: String) -> Bool
    /// Removes the item for `account`. Returns whether it is gone.
    @discardableResult
    func delete(_ account: String) -> Bool
}

/// A `KeychainStoring` that forgets on process exit. The check modes use it so a
/// headless run can neither block on the consent prompt nor leave items behind;
/// the migration tests use it so no test ever touches the real Keychain.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func get(_ account: String) -> String? {
        lock.withLock { values[account] }
    }

    public func set(_ account: String, value: String) -> Bool {
        lock.withLock { values[account] = value }
        return true
    }

    public func delete(_ account: String) -> Bool {
        lock.withLock { values.removeValue(forKey: account) }
        return true
    }
}

public struct KeychainStore: KeychainStoring {
    public init() {}
    /// The service every item is filed under. Written as a literal rather than
    /// read from `Bundle.main` so the store behaves identically in the app and
    /// in the self-test binary, which has no bundle.
    private static let service = "com.mriver15.bud"

    public func get(_ account: String) -> String? {
        var query = Self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query = Self.baseQuery(account: account)

        // Prefer an update, which preserves the item's accessibility; fall back
        // to adding when nothing exists to update.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var add = Self.baseQuery(account: account)
        add[kSecValueData as String] = data
        // A menu-bar app must be able to read its keys after login but before
        // the first unlock, so the items are readable after first unlock rather
        // than after *this* unlock.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        let status = SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
