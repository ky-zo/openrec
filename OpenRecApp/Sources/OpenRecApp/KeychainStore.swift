import Foundation
import Security

enum KeychainStore {
    // Development builds use their own Keychain namespace. This prevents a
    // newly signed dev app from blocking SwiftUI layout while macOS asks for
    // access to credentials created by the production app.
    private static var service: String {
#if DEBUG
        "app.openrec.credentials.dev"
#else
        "app.openrec.credentials"
#endif
    }

    static func string(for key: String) -> String {
        var query: [String: Any] = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func set(_ value: String, for key: String) {
        let query = baseQuery(for: key)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
