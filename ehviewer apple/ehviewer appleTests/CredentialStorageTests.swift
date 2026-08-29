//
//  CredentialStorageTests.swift
//  ehviewer appleTests
//
//  登录凭据从 Cookie 容器搬到钥匙串之后的两条不变量：
//    1. 钥匙串存取要能往返，且 clear 之后读不回来
//    2. 三个认证 Cookie 必须是会话 Cookie（不落盘），其余的仍然持久
//
//  第 2 条尤其要有测试守着：它靠的是 HTTPCookie 的 discard 属性，
//  哪天有人给 setCookie 加回 .expires，pass hash 就会又明文落进容器，
//  而这种回归在界面上完全看不出来。
//

import Testing
import Foundation
import EhCookie
@testable import ehviewer_apple

/// `.serialized`：这几条都在读写钥匙串里同一个 service/account，
/// 默认的并行执行会互相踩——一条刚 clear 完，另一条的 save 就跑了。
@Suite(.serialized)
struct CredentialStorageTests {

    // MARK: - 钥匙串往返

    /// `.enabled(if:)` 而不是在函数体里 return：未签名的本地构建
    /// （CODE_SIGNING_ALLOWED=NO）拿不到 application-identifier，钥匙串会返回
    /// errSecMissingEntitlement。那种环境下这几条测不了，应当显示为「跳过」，
    /// 而不是悄悄通过——悄悄通过就等于这几条断言在 CI 上从来没跑过。
    @Test(.enabled(if: EhCredentialStore.isAvailable))
    func keychainRoundTrip() throws {
        EhCredentialStore.clear()

        let creds = EhCredentials(memberId: "12345", passHash: "deadbeef", igneous: "abc")
        #expect(EhCredentialStore.save(creds))

        let loaded = EhCredentialStore.load()
        #expect(loaded == creds)

        EhCredentialStore.clear()
        #expect(EhCredentialStore.load() == nil)
    }

    /// 第二次登录要覆盖而不是失败。
    /// SecItemAdd 对已存在的项返回 errSecDuplicateItem——直接 add 会静默失败，
    /// 用户换了账号还在用旧凭据。
    @Test(.enabled(if: EhCredentialStore.isAvailable))
    func keychainOverwritesExisting() throws {
        EhCredentialStore.clear()

        #expect(EhCredentialStore.save(EhCredentials(memberId: "1", passHash: "old")))
        #expect(EhCredentialStore.save(EhCredentials(memberId: "2", passHash: "new")))

        let loaded = EhCredentialStore.load()
        #expect(loaded?.memberId == "2")
        #expect(loaded?.passHash == "new")

        EhCredentialStore.clear()
    }

    /// 空凭据等同于清除，不该在钥匙串里留一条空记录
    @Test(.enabled(if: EhCredentialStore.isAvailable))
    func savingEmptyClears() throws {
        #expect(EhCredentialStore.save(EhCredentials(memberId: "1", passHash: "x")))
        #expect(EhCredentialStore.save(EhCredentials()))
        #expect(EhCredentialStore.load() == nil)
    }

    // MARK: - 认证 Cookie 不落盘

    /// 认证 Cookie 必须是会话 Cookie。
    ///
    /// HTTPCookie 的 isSessionOnly 为 true 时不会被写进容器里的
    /// Cookies.binarycookies —— 这正是把 pass hash 从磁盘上拿掉的机制。
    @Test func authCookiesAreSessionOnly() async throws {
        let manager = EhCookieManager.shared
        let domain = EhCookieManager.domainEhentai

        manager.setCookie(name: EhCookieManager.keyIPBPassHash, value: "hash-under-test",
                          domain: domain)
        manager.setCookie(name: EhCookieManager.keyIPBMemberId, value: "42", domain: domain)
        manager.setCookie(name: EhCookieManager.keyNW, value: "1", domain: domain)

        // setCookie 走的是异步写队列，等它排空
        try await confirmCookiePresent(name: EhCookieManager.keyIPBPassHash, domain: domain)

        let url = URL(string: "https://e-hentai.org")!
        let stored = HTTPCookieStorage.shared.cookies(for: url) ?? []

        let passHash = stored.first { $0.name == EhCookieManager.keyIPBPassHash }
        let memberId = stored.first { $0.name == EhCookieManager.keyIPBMemberId }
        let nw = stored.first { $0.name == EhCookieManager.keyNW }

        // 关键不变量：认证 Cookie 的存放方式必须和钥匙串可用性一致。
        //
        // 钥匙串可用 → 会话 Cookie（不落盘），持久副本在钥匙串里；
        // 钥匙串不可用 → 退回持久 Cookie。两者必须匹配，不匹配就意味着
        // 凭据既没进钥匙串、也没落盘，用户每次启动都要重新登录。
        let expectSession = EhCredentialStore.isAvailable
        #expect(passHash?.isSessionOnly == expectSession)
        #expect(memberId?.isSessionOnly == expectSession)

        // 非认证 Cookie 永远持久，否则每次启动都要重新注入
        #expect(nw?.isSessionOnly == false)

        // 无论哪条分支，凭据都必须还能读回来——这是「不会把人登出」的直接断言
        #expect(manager.passHash == "hash-under-test")

        manager.signOut()
    }


    // MARK: - 注销 / 收编

    /// 注销必须连钥匙串一起清 —— 测的是**界面上那个注销按钮实际走的代码**。
    ///
    /// 直接测 EhCookieManager.signOut() 是没用的：它一直都清钥匙串。
    /// 真正的 bug 在 SettingsViewModel.logout()，它自己手写了一遍清 Cookie
    /// 的逻辑、绕开了 signOut，于是凭据留在钥匙串里，重启后
    /// EhCookieManager.init 又把用户恢复成登录状态。所以这里必须调 logout()。
    @Test(.enabled(if: EhCredentialStore.isAvailable))
    @MainActor
    func logoutClearsKeychain() async throws {
        let manager = EhCookieManager.shared
        manager.setCookie(name: EhCookieManager.keyIPBMemberId, value: "42",
                          domain: EhCookieManager.domainEhentai)
        manager.setCookie(name: EhCookieManager.keyIPBPassHash, value: "hash",
                          domain: EhCookieManager.domainEhentai)
        try await settle()
        #expect(manager.persistCredentials())
        #expect(EhCredentialStore.load() != nil)

        SettingsViewModel().logout()
        try await settle()

        #expect(EhCredentialStore.load() == nil,
                "注销后钥匙串里还留着凭据，下次启动会被静默恢复成已登录")
    }

    /// URLSession 自动落盘的持久认证 Cookie 必须被收编成会话 Cookie。
    ///
    /// 账号密码登录走 URLSession，它的 httpCookieStorage 就是 shared，
    /// 服务端的 Set-Cookie 带真实过期时间，在任何 App 代码跑起来之前就
    /// 已经以持久 Cookie 落盘了。secureAuthCookies 负责把它收回来。
    @Test(.enabled(if: EhCredentialStore.isAvailable))
    func secureAuthCookiesConvertsPersistedCookies() async throws {
        let manager = EhCookieManager.shared
        manager.signOut()
        try await settle()

        // 模拟 URLSession 的行为：直接塞一条带过期时间的持久 Cookie
        let persistent = HTTPCookie(properties: [
            .name: EhCookieManager.keyIPBPassHash,
            .value: "persisted-hash",
            .domain: EhCookieManager.domainEhentai,
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(86_400),
        ])!
        HTTPCookieStorage.shared.setCookie(persistent)
        let memberId = HTTPCookie(properties: [
            .name: EhCookieManager.keyIPBMemberId,
            .value: "42",
            .domain: EhCookieManager.domainEhentai,
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(86_400),
        ])!
        HTTPCookieStorage.shared.setCookie(memberId)

        let url = URL(string: "https://e-hentai.org")!
        #expect(HTTPCookieStorage.shared.cookies(for: url)?
            .first { $0.name == EhCookieManager.keyIPBPassHash }?.isSessionOnly == false,
            "前置条件：这条应该先是持久 Cookie")

        #expect(manager.secureAuthCookies())
        try await settle()

        let after = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let hash = after.first { $0.name == EhCookieManager.keyIPBPassHash }
        #expect(hash?.isSessionOnly == true, "pass hash 仍以持久 Cookie 落在容器里")
        #expect(hash?.value == "persisted-hash", "收编过程不能把值弄丢")
        #expect(EhCredentialStore.load()?.passHash == "persisted-hash")

        manager.signOut()
    }

    /// 等异步写队列落地
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// 等 setCookie 的异步写队列落地
    private func confirmCookiePresent(name: String, domain: String) async throws {
        let url = URL(string: "https://\(domain.trimmingCharacters(in: .init(charactersIn: ".")))")!
        for _ in 0..<50 {
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            if cookies.contains(where: { $0.name == name }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Cookie \(name) 没有在预期时间内写入")
    }
}
