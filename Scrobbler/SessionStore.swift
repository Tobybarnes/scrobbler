import Foundation
import Security

enum SessionStoreError: Error {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}

class SessionStore {
    private let service: String
    private let account: String

    init(service: String = "com.tobybarnes.scrobbler",
         account: String = "lastfm-session") {
        self.service = service
        self.account = account
    }

    func save(_ sessionKey: String) throws {
        guard let data = sessionKey.data(using: .utf8) else { return }

        // Delete any existing entry first (update is fiddly, delete+add is reliable)
        try? delete()

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionStoreError.saveFailed(status)
        }
    }

    func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.deleteFailed(status)
        }
    }
}
