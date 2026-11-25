import Foundation
import Testing
@testable import EhSettings

struct ProxySettingsTests {
    @Test func draftAndInvalidApplyDoNotChangeTheSavedEffectiveProxy() throws {
        try withDefaults { defaults in
            defaults.set(1, forKey: "proxy_mode")
            defaults.set("legacy.invalid", forKey: "proxy_host")
            defaults.set(8080, forKey: "proxy_port")
            let settings = AppSettings(defaults: defaults)
            var draft = settings.appliedProxy
            draft.host = "new.invalid"
            #expect(settings.appliedProxy.host == "legacy.invalid")
            draft.port = 0
            #expect(throws: ProxySettings.ValidationError.invalidEndpoint) { try settings.applyProxy(draft) }
            #expect(settings.appliedProxy.host == "legacy.invalid")
            #expect(defaults.dictionary(forKey: "applied_proxy") == nil)

            draft.port = 3128
            try settings.applyProxy(draft)
            let reopened = AppSettings(defaults: defaults)
            #expect(reopened.appliedProxy == draft)
            #expect(reopened.appliedProxy.connectionProxyDictionary?["HTTPSProxy"] as? String == "new.invalid")
            #expect(reopened.appliedProxy.connectionProxyDictionary?["HTTPPort"] as? Int == 3128)
            #expect(defaults.string(forKey: "proxy_host") == "legacy.invalid")

            draft.mode = 0
            try reopened.applyProxy(draft)
            #expect(settings.appliedProxy == draft)
            #expect(settings.appliedProxy.connectionProxyDictionary == nil)
        }
    }

    @Test func validationRejectsIncompleteEndpointsAndNormalizesHost() throws {
        for draft in [
            ProxySettings(mode: 1, host: "", port: 7890),
            ProxySettings(mode: 1, host: "a b", port: 7890),
            ProxySettings(mode: 1, host: "http://a.invalid", port: 7890),
            ProxySettings(mode: 1, host: "a.invalid", port: 65536),
        ] {
            #expect(throws: ProxySettings.ValidationError.invalidEndpoint) { try draft.validated() }
            #expect(draft.connectionProxyDictionary == nil)
        }
        let valid = try ProxySettings(mode: 1, host: "  127.0.0.1 ", port: 65535).validated()
        #expect(valid.host == "127.0.0.1")
        #expect(valid.connectionProxyDictionary?["HTTPSEnable"] as? Int == 1)
        #expect(valid.connectionProxyDictionary?["HTTPProxy"] as? String == "127.0.0.1")
        #expect(valid.connectionProxyDictionary?["HTTPSPort"] as? Int == 65535)
    }

    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let name = "EhProxyFixture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }
}
