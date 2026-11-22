import Testing
@testable import ehviewer_apple

@MainActor
struct StartupGateTests {
    @Test func firstLaunchKeepsWarningSiteAndLoginInOrder() {
        let gate = StartupGate()
        #expect(gate.nextStep(showWarning: true, lockEnabled: false, hasSelectedSite: false) {
            Issue.record("Do not resolve a session before warning acknowledgement")
            return true
        } == .warning)
        #expect(gate.nextStep(showWarning: false, lockEnabled: false, hasSelectedSite: false) {
            Issue.record("Do not resolve a session before site selection")
            return true
        } == .selectSite)
        #expect(gate.nextStep(showWarning: false, lockEnabled: false, hasSelectedSite: true) { false } == .login)
        #expect(gate.nextStep(showWarning: false, lockEnabled: false, hasSelectedSite: true) { true } == .main)
    }

    @Test func warningAcknowledgementCannotSubstituteForAnEnabledLock() {
        var gate = StartupGate()
        var sessionResolutions = 0
        let resolveSession = {
            sessionResolutions += 1
            return true  // a valid login or guest session is not lock authentication
        }
        #expect(gate.nextStep(showWarning: true, lockEnabled: true, hasSelectedSite: true, canEnterApp: resolveSession) == .warning)
        #expect(gate.nextStep(showWarning: false, lockEnabled: true, hasSelectedSite: true, canEnterApp: resolveSession) == .security)
        #expect(sessionResolutions == 0)
        gate.didAuthenticate()
        #expect(gate.nextStep(showWarning: false, lockEnabled: true, hasSelectedSite: true, canEnterApp: resolveSession) == .main)
        #expect(sessionResolutions == 1)
    }

    @Test func completedUnlockSurvivesSiteChoiceButNotAnExplicitRelock() {
        var gate = StartupGate()
        gate.didAuthenticate()
        #expect(gate.nextStep(showWarning: false, lockEnabled: true, hasSelectedSite: false) { false } == .selectSite)
        #expect(gate.nextStep(showWarning: false, lockEnabled: true, hasSelectedSite: true) { false } == .login)
        gate.requireAuthentication()
        #expect(gate.nextStep(showWarning: false, lockEnabled: true, hasSelectedSite: true) { true } == .security)
    }
}
