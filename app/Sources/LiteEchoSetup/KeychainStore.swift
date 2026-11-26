import Foundation
import LiteEchoCore
import Security

/// The Hugging Face token, kept as a generic password in the login keychain.
/// Service and account are injectable so tests never touch the real item.
public struct KeychainStore: Sendable {
    /// `var` only so the LiteEchoSnapshots tool can point it at an unused service and never
    /// read the user's real item. The app never changes it.
    public nonisolated(unsafe) static var defaultService = "dev.liteecho.app"
    public static let defaultAccount = "huggingface-token"

    public struct KeychainError: Error, LocalizedError, Equatable {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    public let service: String
    public let account: String

    public init(service: String = KeychainStore.defaultService,
                account: String = KeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Stores the token, replacing any existing one.
    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public var hasToken: Bool { !(load() ?? "").isEmpty }

    /// Removes the token. Not an error when there is none.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

extension KeychainStore {
    /// Moves the token from the former service name to `new`: reads the old item, saves it
    /// under the new service (unless that already holds a token) and deletes the old item.
    /// The token is never logged. Returns true when an old item was found and removed.
    @discardableResult
    public static func migrateLegacyToken(to new: KeychainStore = KeychainStore(),
                                          from old: KeychainStore = KeychainStore(service: LegacyMigration.legacyKeychainService)) -> Bool {
        guard old.service != new.service, let token = old.load(), !token.isEmpty else { return false }
        if !new.hasToken {
            guard (try? new.save(token)) != nil else { return false }   // keep the old one if saving failed
        }
        return (try? old.delete()) != nil
    }
}
