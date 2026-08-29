//
//  EhCredentialStore.swift
//  EhCookie
//
//  登录凭据的钥匙串存储
//
//  `ipb_pass_hash` 是长期凭据，泄露等同于账号被接管。它此前只存在
//  `HTTPCookieStorage` 里，也就是 App 容器内的 Cookies.binarycookies ——
//  明文、随未加密备份一起走、越狱设备上可直接读。
//
//  这里把三个认证 Cookie 的**持久副本**移到钥匙串，用
//  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：设备解锁过一次之后
//  才可读，不进 iCloud 钥匙串，也不随备份迁到别的设备。
//
//  Cookie 罐里仍然有一份，但改成了会话 Cookie（不落盘），进程退出即消失，
//  下次启动由钥匙串恢复。
//

import Foundation
import Security

public struct EhCredentials: Codable, Sendable, Equatable {
    public var memberId: String?
    public var passHash: String?
    public var igneous: String?

    public init(memberId: String? = nil, passHash: String? = nil, igneous: String? = nil) {
        self.memberId = memberId
        self.passHash = passHash
        self.igneous = igneous
    }

    public var isEmpty: Bool {
        memberId == nil && passHash == nil && igneous == nil
    }
}

public enum EhCredentialStore {
    private static let service = "com.ehviewer.credentials"
    private static let account = "eh-session"

    /// 钥匙串这台机器上能不能用。
    ///
    /// 未签名 / 缺 application-identifier 的构建（本地 CODE_SIGNING_ALLOWED=NO
    /// 跑出来的调试包就是）访问钥匙串会拿到 errSecMissingEntitlement (-34018)。
    /// 这件事必须能被上层问到：不问就意味着「存不进去也不吭声」，
    /// 而认证 Cookie 已经改成了不落盘的会话 Cookie —— 两件事叠在一起
    /// 就是每次启动都掉登录。
    public static var isAvailable: Bool {
        if let cached = availabilityCache { return cached }
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "availability-probe",
            kSecValueData as String: Data([0]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(probeQuery as CFDictionary)
        let status = SecItemAdd(probeQuery as CFDictionary, nil)
        let ok = (status == errSecSuccess || status == errSecDuplicateItem)
        if ok { SecItemDelete(probeQuery as CFDictionary) } else { lastError = status }
        availabilityCache = ok
        return ok
    }

    private nonisolated(unsafe) static var availabilityCache: Bool?

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func load() -> EhCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(EhCredentials.self, from: data)
        else { return nil }
        return creds
    }

    @discardableResult
    public static func save(_ credentials: EhCredentials) -> Bool {
        guard !credentials.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(credentials) else { return false }

        // 先试更新，没有再插入。SecItemAdd 对已存在的项会返回 errSecDuplicateItem，
        // 直接 add 会在第二次登录时静默失败。
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            lastError = addStatus
        }
        return addStatus == errSecSuccess
    }

    /// 最近一次失败的 OSStatus，供诊断用。
    /// 钥匙串失败必须能看见——静默失败的后果是每次启动都掉登录。
    public private(set) nonisolated(unsafe) static var lastError: OSStatus = errSecSuccess

    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
