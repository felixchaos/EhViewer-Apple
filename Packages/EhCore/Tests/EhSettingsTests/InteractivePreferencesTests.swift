import Foundation
import Observation
import Testing
import os
@testable import EhSettings

struct InteractivePreferencesTests {
    @Test func settingsControlWritesNotifyObserversAndPreserveStoredValues() throws {
        let suite = "EhViewer.InteractivePreferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        func verify<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value) {
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = settings[keyPath: keyPath]
            } onChange: {
                changed.withLock { $0 = true }
            }

            settings[keyPath: keyPath] = value
            #expect(changed.withLock { $0 })
            #expect(settings[keyPath: keyPath] == value)
            #expect(AppSettings(defaults: defaults)[keyPath: keyPath] == value)
        }

        verify(\.readingDirection, 1)
        verify(\.pageScaling, 1)
        verify(\.customScreenLightness, true)
        verify(\.screenLightness, 76)
        verify(\.colorFilter, true)
        verify(\.showPageInterval, true)
        verify(\.enableSecureScreen, true)
        verify(\.securityDelay, 30)
        verify(\.defaultFavSlot, 5)
        verify(\.thumbResolution, 1)
        verify(\.fixThumbUrl, true)
        verify(\.readCacheSize, 160)
        verify(\.cellularNetworkWarning, true)
        verify(\.syncDownloadWhileReading, true)
        verify(\.showLiveActivity, false)
        verify(\.builtExHosts, true)
        verify(\.saveParseErrorBody, true)
    }
}
