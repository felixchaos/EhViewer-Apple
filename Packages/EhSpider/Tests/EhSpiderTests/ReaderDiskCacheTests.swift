import Foundation
import Testing
@testable import EhSpider

@Suite struct ReaderDiskCacheTests {
    @Test func asyncReadReturnsBytesAndMissAndRefreshesOrderForTrim() async throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SimpleDiskCache(directory: directory, maxSize: 4)
        #expect(cache.set(Data([1, 1]), forKey: "first"))
        #expect(cache.set(Data([2, 2]), forKey: "second"))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let bytes = try Data(contentsOf: file)
            let timestamp = bytes == Data([1, 1]) ? 1_000.0 : 2_000.0
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: file.path
            )
        }

        #expect(await cache.getDataAsync(forKey: "absent") == nil)
        #expect(await cache.getDataAsync(forKey: "first") == Data([1, 1]))
        // The refreshed first entry survives even though it had been older
        // than second before the new read. Sync and async paths share a queue.
        #expect(cache.set(Data([3]), forKey: "third"))
        #expect(await cache.getDataAsync(forKey: "second") == nil)
        #expect(await cache.getDataAsync(forKey: "first") == Data([1, 1]))
        #expect(cache.getData(forKey: "third") == Data([3]))
    }

    @MainActor @Test func queuedReadLetsMainActorReleaseEarlierDiskWork() async throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "ehviewer.test.reader-cache")
        let cache = SimpleDiskCache(directory: directory, maxSize: 100, queue: queue)
        #expect(cache.set(Data([1]), forKey: "image"))
        let file = try #require(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first)
        let gate = DispatchSemaphore(value: 0)
        let diskState = AsyncStream<Bool>.makeStream()
        queue.async {
            // Runs ahead of the async read. If the read occupies MainActor
            // while waiting here, MainActor can't release the gate in time.
            let unblocked = gate.wait(timeout: .now() + 5) == .success
            try? Data([2]).write(to: file)
            diskState.continuation.yield(unblocked)
            diskState.continuation.finish()
        }

        let starting = AsyncStream<Void>.makeStream()
        let reader = Task { @MainActor in
            starting.continuation.yield()
            starting.continuation.finish()
            return await cache.getDataAsync(forKey: "image")
        }
        var started = starting.stream.makeAsyncIterator()
        _ = await started.next()
        gate.signal()
        var state = diskState.stream.makeAsyncIterator()
        #expect(await state.next() == true)
        #expect(await reader.value == Data([2]))
    }

    private func makeCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EhReaderDiskCache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
