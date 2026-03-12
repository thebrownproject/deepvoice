import Foundation
import Security
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "KeychainHelper")

enum KeychainAccount: String, CaseIterable {
    case deepgramAPIKey
    case openRouterAPIKey
    case openAIAPIKey
}

enum KeychainHelper {
    private static let service = "com.thebrownproject.deepvoice"

    private static func notifyKeyChange(for account: KeychainAccount) {
        NotificationCenter.default.post(
            name: .deepVoiceAPIKeysDidChange,
            object: nil,
            userInfo: ["account": account.rawValue]
        )
    }

    private static func baseQuery(for account: KeychainAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for account: KeychainAccount) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        let query = baseQuery(for: account)
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            log.error("Failed to clear existing key for \(account.rawValue) (status: \(deleteStatus))")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            log.info("Key saved for \(account.rawValue)")
            notifyKeyChange(for: account)
            return true
        }
        log.error("Failed to save key for \(account.rawValue) (status: \(status))")
        return false
    }

    static func loadAPIKey(for account: KeychainAccount) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.error("Failed to load key for \(account.rawValue) (status: \(status))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteAPIKey(for account: KeychainAccount) -> Bool {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            log.info("Key deleted for \(account.rawValue)")
            notifyKeyChange(for: account)
            return true
        }
        log.error("Failed to delete key for \(account.rawValue) (status: \(status))")
        return false
    }
}
