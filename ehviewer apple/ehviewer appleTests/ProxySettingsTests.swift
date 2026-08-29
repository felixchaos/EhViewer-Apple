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
