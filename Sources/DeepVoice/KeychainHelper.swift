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

        // Try Keychain first
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            log.info("Key saved to Keychain for \(account.rawValue)")
            // Also save to file so it persists across unsigned builds
            FileKeyStore.save(key, for: account)
            return true
        }

        // Keychain failed (unsigned build), fall back to file
        log.warning("Keychain save failed for \(account.rawValue) (status: \(status)), using file fallback")
        FileKeyStore.save(key, for: account)
        return true
    }

    static func loadAPIKey(for account: KeychainAccount) -> String? {
        // Try Keychain first
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }

        // Fall back to file
        if let key = FileKeyStore.load(for: account) {
            return key
        }

        if status != errSecItemNotFound {
            log.error("Failed to load key for \(account.rawValue) (status: \(status))")
        }
        return nil
    }

    @discardableResult
    static func deleteAPIKey(for account: KeychainAccount) -> Bool {
        SecItemDelete(baseQuery(for: account) as CFDictionary)
        FileKeyStore.delete(for: account)
        log.info("Key deleted for \(account.rawValue)")
        return true
    }
}

// MARK: - File-based fallback for unsigned builds

private enum FileKeyStore {
    private static let keysPath = DeepVoiceConfig.dataDir.appendingPathComponent("keys.json")

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: keysPath),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeAll(_ dict: [String: String]) {
        DeepVoiceConfig.bootstrapStorage()
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let fm = FileManager.default
        fm.createFile(atPath: keysPath.path, contents: data)
        // Restrict to owner-only read/write (chmod 600)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysPath.path)
    }

    static func save(_ key: String, for account: KeychainAccount) {
        var dict = loadAll()
        dict[account.rawValue] = key
        writeAll(dict)
    }

    static func load(for account: KeychainAccount) -> String? {
        loadAll()[account.rawValue]
    }

    static func delete(for account: KeychainAccount) {
        var dict = loadAll()
        dict.removeValue(forKey: account.rawValue)
        writeAll(dict)
    }
}
