/// Runs a bounded page pipeline. A failed attempt requeues for the next pass
/// rather than occupying a worker until every retry and backoff is exhausted.
enum DownloadPageBatch {
    /// Return true from operation to retry this page after untouched pages.
    static func run(
        pages: [Int], concurrency: Int, attemptLimit: Int = 5,
        retryDelay: @Sendable (Int) async -> Void,
        operation: @escaping @Sendable (Int, Bool) async -> Bool
    ) async {
        guard !pages.isEmpty, attemptLimit > 0 else { return }
        var pending = pages
        let limit = max(1, concurrency)
        for attempt in 0..<attemptLimit {
            guard !Task.isCancelled, !pending.isEmpty else { return }
            let final = attempt == attemptLimit - 1
            let round = pending
            pending = await withTaskGroup(of: Int?.self) { group in
                var next = 0
                var retries: [Int] = []
                while next < min(round.count, limit) {
                    let page = round[next]
                    guard group.addTaskUnlessCancelled(operation: {
                        await operation(page, final) ? page : nil
                    }) else { break }
                    next += 1
                }
                while let result = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let page = result { retries.append(page) }
                    if next < round.count {
                        let page = round[next]
                        if group.addTaskUnlessCancelled(operation: {
                            await operation(page, final) ? page : nil
                        }) { next += 1 }
                    }
                }
                return retries.sorted()
            }
            if !final, !pending.isEmpty, !Task.isCancelled { await retryDelay(attempt) }
        }
    }
}
