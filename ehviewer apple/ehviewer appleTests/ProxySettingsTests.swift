//
//  ProxySettingsTests.swift
//  ehviewer appleTests
//
//  代理配置最重要的性质是「配不全就别碰网络」。
//
//  这个 App 的连通性本来就脆（DNS 污染、SNI 拦截、域名前置回退），
//  一个只填了地址没填端口的代理如果被当成有效配置塞进
//  connectionProxyDictionary，用户会得到一个完全连不上、又不知道为什么的
//  App。所以宁可当作没配。
//

import Testing
import Foundation
import EhSettings

@Suite(.serialized)
@MainActor
struct ProxySettingsTests {

    private func reset() {
        AppSettings.shared.proxyMode = 0
        AppSettings.shared.proxyHost = ""
        AppSettings.shared.proxyPort = 0
    }

    @Test func systemModeIsNotManual() {
        reset()
        #expect(!AppSettings.shared.manualProxyIsUsable)
    }

    @Test func manualNeedsBothHostAndPort() {
        reset()
        AppSettings.shared.proxyMode = 1

        AppSettings.shared.proxyHost = "127.0.0.1"
        #expect(!AppSettings.shared.manualProxyIsUsable, "只有地址没有端口不该生效")

        AppSettings.shared.proxyHost = ""
        AppSettings.shared.proxyPort = 7890
        #expect(!AppSettings.shared.manualProxyIsUsable, "只有端口没有地址不该生效")

        AppSettings.shared.proxyHost = "127.0.0.1"
        #expect(AppSettings.shared.manualProxyIsUsable)
        reset()
    }

    /// 端口必须在合法范围内，否则同样按没配处理
    @Test func portMustBeInRange() {
        reset()
        AppSettings.shared.proxyMode = 1
        AppSettings.shared.proxyHost = "127.0.0.1"

        AppSettings.shared.proxyPort = 0
        #expect(!AppSettings.shared.manualProxyIsUsable)

        AppSettings.shared.proxyPort = 70000
        #expect(!AppSettings.shared.manualProxyIsUsable)

        AppSettings.shared.proxyPort = 65535
        #expect(AppSettings.shared.manualProxyIsUsable)
        reset()
    }
}

// MARK: - 设置项之间不能串键

/// 两个设置共用一个 UserDefaults 键，表现是「开 A 顺带开了 B」。
///
/// 这不是假想：新加的「切到后台时隐藏内容」(enableSecureScreen) 一开始沿用了
/// Android 的键名 `enable_secure`，而本项目里那个键早就被应用锁
/// (enableSecurity) 占着了——打开隐私遮罩会连应用锁一起打开，模拟器上直接
/// 被锁在验证界面外面。这里针对那对具体的设置守住。
@Suite(.serialized)
@MainActor
struct SettingsKeyIsolationTests {

    @Test func secureScreenDoesNotToggleAppLock() {
        let settings = AppSettings.shared
        let originalLock = settings.enableSecurity
        let originalScreen = settings.enableSecureScreen
        defer {
            settings.enableSecurity = originalLock
            settings.enableSecureScreen = originalScreen
        }

        settings.enableSecurity = false
        settings.enableSecureScreen = true
        #expect(!settings.enableSecurity, "开隐私遮罩把应用锁也打开了 —— 两者共用了同一个键")

        settings.enableSecureScreen = false
        settings.enableSecurity = true
        #expect(!settings.enableSecureScreen, "开应用锁把隐私遮罩也打开了")
    }
}
