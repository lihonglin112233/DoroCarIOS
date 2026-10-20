import Foundation

/// 车联网登录凭据的加密存储。
///
/// **为什么不能明文落盘**：里面是 accessToken / refreshToken，拿到即可远程
/// 解锁、启动发动机。iOS 上对应 Android Keystore 的是 Keychain：
/// 条目由系统加密、按应用隔离，卸载应用即清除。
///
/// 存储内容是整个会话 JSON（与 Android 侧一致），读写都在 Keychain 中完成，
/// 不使用 UserDefaults——后者是明文 plist。
enum CredentialStore {

    private static let service = "com.dorocar.car.credentials"
    private static let account = "gwm_session"

    /// 是否存有凭据（只查存在性，不读取内容）
    static func hasCredentials() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// 读出会话字典；没有或格式异常时返回 nil。
    static func loadState() -> [String: Any]? {
        guard let data = read() else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func save(_ state: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(state) else {
            throw GwmError.crypto("凭据不是合法 JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: state, options: [])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            // 只要设备解锁过一次即可访问：后台刷新车况需要在锁屏时也能读
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attrs) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GwmError.crypto("Keychain 写入失败（\(addStatus)）")
            }
        } else if status != errSecSuccess {
            throw GwmError.crypto("Keychain 更新失败（\(status)）")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
}
