import Foundation
import Security

struct LastFMCredentials: Equatable {
    let apiKey: String
    let sharedSecret: String
}

enum CredentialStoreError: Error, LocalizedError {
    case invalidCredentials
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Enter both a Last.fm API key and shared secret."
        case .saveFailed(let status): return "Could not save Last.fm credentials (Keychain status \(status))."
        }
    }
}

final class CredentialStore {
    private let service = "com.tobybarnes.scrobbler.credentials"
    private let apiKeyAccount = "lastfm-api-key"
    private let sharedSecretAccount = "lastfm-shared-secret"

    func load() -> LastFMCredentials? {
        guard let apiKey = read(account: apiKeyAccount),
              let sharedSecret = read(account: sharedSecretAccount),
              !apiKey.isEmpty,
              !sharedSecret.isEmpty else { return nil }
        return LastFMCredentials(apiKey: apiKey, sharedSecret: sharedSecret)
    }

    func save(_ credentials: LastFMCredentials) throws {
        guard !credentials.apiKey.isEmpty, !credentials.sharedSecret.isEmpty else {
            throw CredentialStoreError.invalidCredentials
        }
        try write(credentials.apiKey, account: apiKeyAccount)
        try write(credentials.sharedSecret, account: sharedSecretAccount)
    }

    private func read(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw CredentialStoreError.invalidCredentials }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let lookup: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let update: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CredentialStoreError.saveFailed(updateStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.saveFailed(status)
        }
    }
}
