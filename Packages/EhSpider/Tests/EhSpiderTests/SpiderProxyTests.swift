import Foundation
import Testing
@testable import EhSpider

struct SpiderProxyTests {
    @Test func newSessionUsesAppliedManualProxyAndRetainsTransferTimeouts() {
        let configuration = SpiderQueen.sessionConfiguration(
            inactivity: 60, proxy: .init(mode: 1, host: "fixture.invalid", port: 8080)
        )
        #expect(configuration.connectionProxyDictionary?["HTTPProxy"] as? String == "fixture.invalid")
        #expect(configuration.connectionProxyDictionary?["HTTPSPort"] as? Int == 8080)
        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 240)
        let system = SpiderQueen.sessionConfiguration(
            inactivity: 60, proxy: .init(mode: 0, host: "fixture.invalid", port: 8080)
        )
        #expect(system.connectionProxyDictionary == nil)
    }
}
