/// Admission policy for startup and returning from the app-lock screen.
/// Authentication is an in-memory grant for this activation, never a saved preference.
struct StartupGate {
    enum Step: Equatable {
        case warning, rejected, security, selectSite, login, main
    }

    private var authenticated = false

    mutating func didAuthenticate() {
        authenticated = true
    }

    mutating func requireAuthentication() {
        authenticated = false
    }

    /// Session lookup may initialize credentials, so do not call it before the
    /// warning, lock and site choice have all been resolved.
    func nextStep(
        showWarning: Bool,
        lockEnabled: Bool,
        hasSelectedSite: Bool,
        canEnterApp: () -> Bool
    ) -> Step {
        if showWarning { return .warning }
        if lockEnabled && !authenticated { return .security }
        if !hasSelectedSite { return .selectSite }
        return canEnterApp() ? .main : .login
    }
}
