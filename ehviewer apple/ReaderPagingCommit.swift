/// Logical page state is deliberately separate from the native ScrollView's
/// live anchor. Scroll moves with the finger; history/chrome commit on rest.
struct ReaderPagingCommit {
    enum Outcome: Equatable {
        case unchanged
        case move(to: Int)
        case restoreExplicitAnchor
    }

    private var originalPage: Int?
    private var superseded = false

    /// Covers touch tracking, panning, deceleration, and a second touch that
    /// interrupts deceleration. Don't start a new session until the view rests.
    mutating func begin(from logicalPage: Int) {
        if originalPage == nil {
            originalPage = logicalPage
            superseded = false
        }
    }

    mutating func explicitPageChanged() {
        if originalPage != nil { superseded = true }
    }

    mutating func settle(logicalPage: Int, candidate: Int?, totalPages: Int) -> Outcome {
        defer { self = ReaderPagingCommit() }
        guard let originalPage else { return .unchanged }
        // Compare the origin as well as the change event; a programmatic
        // jump can arrive in the same transaction as the idle callback.
        guard !superseded, originalPage == logicalPage else { return .restoreExplicitAnchor }
        guard let candidate, candidate >= 0, candidate < totalPages, candidate != logicalPage else {
            return .unchanged
        }
        return .move(to: candidate)
    }
}
