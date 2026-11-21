//
//  ehviewer_appleTests.swift
//  ehviewer appleTests
//
//  Created by 晓卡 on 2026/2/12.
//

import Foundation
import Testing
@testable import ehviewer_apple

struct ehviewer_appleTests {

    #if targetEnvironment(simulator)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EH_OFFLINE_UNIT_TEST_HOST"] == "1"))
    func optedInUnitTestHostUsesOfflineStartup() {
        #expect(EhUnitTestHost.isOffline)
    }
    #endif

}
