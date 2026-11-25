import Foundation

/// A preview page yields multiple image tokens. Concurrent workers for that
/// page share the request instead of each spending a global network slot.
actor DownloadPreviewRequests {
    private struct InFlight {
        let id: UUID
        let task: Task<[Int: String], Error>
    }
    private var inFlight: [Int: InFlight] = [:]

    func load(
        page: Int, request: @escaping @Sendable () async throws -> [Int: String]
    ) async throws -> [Int: String] {
        try Task.checkCancellation()
        let entry: InFlight
        if let existing = inFlight[page] {
            entry = existing
        } else {
            entry = .init(id: UUID(), task: Task { try await request() })
            inFlight[page] = entry
        }
        defer {
            if inFlight[page]?.id == entry.id { inFlight.removeValue(forKey: page) }
        }
        // The download runner cancels the entire batch, not one page.
        // Propagate cancellation to the shared task and await its drain.
        let tokens = try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            entry.task.cancel()
        }
        try Task.checkCancellation()
        return tokens
    }
}
