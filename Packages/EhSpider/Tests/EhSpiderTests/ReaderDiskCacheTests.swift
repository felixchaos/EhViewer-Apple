import Foundation
import Testing
import os
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

    @MainActor @Test func queuedWriteYieldsMainActorAndPreservesEncodedBytes() async throws {
        let directory = try makeCacheDirectory()
        let queue = DispatchQueue(label: "ehviewer.test.reader-cache-write")
        defer {
            queue.sync {}
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = SimpleDiskCache(directory: directory, maxSize: 100, queue: queue)
        let blocker = DispatchSemaphore(value: 0)
        let work = AsyncStream<Bool>.makeStream()
        queue.async {
            work.continuation.yield(blocker.wait(timeout: .now() + 5) == .success)
            work.continuation.finish()
        }
        let started = AsyncStream<Void>.makeStream()
        let encoded = Data([0xff, 0xd8, 44, 72, 0xff, 0xd9])
        let write = Task { @MainActor in
            started.continuation.yield()
            started.continuation.finish()
            return await cache.setAsync(encoded, forKey: "new-page")
        }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        blocker.signal()
        var result = work.stream.makeAsyncIterator()
        #expect(await result.next() == true)
        #expect(await write.value)
        #expect(await cache.getDataAsync(forKey: "new-page") == encoded)
    }

    @MainActor @Test func cancelledQueuedWriteCannotReplaceAPage() async throws {
        let directory = try makeCacheDirectory()
        let queue = DispatchQueue(label: "ehviewer.test.reader-cache-cancel")
        defer {
            queue.sync {}
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = SimpleDiskCache(directory: directory, maxSize: 100, queue: queue)
        #expect(cache.set(Data([2]), forKey: "page"))
        let blocked = DispatchSemaphore(value: 0)
        queue.async { _ = blocked.wait(timeout: .now() + 5) }
        let started = AsyncStream<Void>.makeStream()
        let old = Task { @MainActor in
            started.continuation.yield()
            started.continuation.finish()
            return await cache.setAsync(Data([1]), forKey: "page")
        }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        old.cancel()
        blocked.signal()
        #expect(await old.value == false)
        #expect(await cache.getDataAsync(forKey: "page") == Data([2]))
        #expect(await cache.setAsync(Data([3]), forKey: "page"))
        #expect(await cache.getDataAsync(forKey: "page") == Data([3]))
    }

    @Test func reducingTheLiveLimitTrimsOnlyOldCacheFilesAndReturnsMeasuredUsage() async throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = OSAllocatedUnfairLock(initialState: 100)
        let queue = DispatchQueue(label: "ehviewer.test.resize-cache")
        let cache = SimpleDiskCache(directory: directory, capacity: { capacity.withLock { $0 } }, queue: queue)
        let untracked = directory.appendingPathComponent("untracked", isDirectory: true)
        try FileManager.default.createDirectory(at: untracked, withIntermediateDirectories: false)
        let protected = untracked.appendingPathComponent("retained")
        try Data([10]).write(to: protected)
        let old = Data(repeating: 7, count: 6)
        let new = Data(repeating: 8, count: 6)
        #expect(cache.set(old, forKey: "older-page"))
        #expect(cache.set(new, forKey: "newer-page"))
        try queue.sync {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent != untracked.lastPathComponent {
                let timestamp = try Data(contentsOf: file) == old ? 1_000.0 : 2_000.0
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: file.path
                )
            }
        }
        capacity.withLock { $0 = 8 }
        #expect(await cache.trimForCurrentCapacity() == 6)
        #expect(cache.getData(forKey: "older-page") == nil)
        #expect(cache.getData(forKey: "newer-page") == new)
        #expect(try Data(contentsOf: protected) == Data([10]))

        capacity.withLock { $0 = 20 }
        #expect(cache.set(old, forKey: "added-after-increase"))
        #expect(await cache.trimForCurrentCapacity() == 12)
        #expect(cache.getData(forKey: "newer-page") == new)
        #expect(cache.getData(forKey: "added-after-increase") == old)
    }

    @MainActor @Test func queuedRefreshUsesTheLatestLimitWithoutBlockingTheUI() async throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = OSAllocatedUnfairLock(initialState: 100)
        let queue = DispatchQueue(label: "ehviewer.test.latest-cache-limit")
        let cache = SimpleDiskCache(directory: directory, capacity: { capacity.withLock { $0 } }, queue: queue)
        #expect(cache.set(Data([1, 2, 3, 4, 5, 6]), forKey: "page"))
        // Drain the trim from the initial write at the initial limit.
        queue.sync {}
        let gate = DispatchSemaphore(value: 0)
        let progressed = AsyncStream<Bool>.makeStream()
        queue.async {
            progressed.continuation.yield(gate.wait(timeout: .now() + 5) == .success)
            progressed.continuation.finish()
        }
        capacity.withLock { $0 = 4 }
        let started = AsyncStream<Void>.makeStream()
        let resize = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            return await cache.trimForCurrentCapacity()
        }
        var readiness = started.stream.makeAsyncIterator()
        _ = await readiness.next()
        capacity.withLock { $0 = 8 }
        gate.signal()
        var completion = progressed.stream.makeAsyncIterator()
        #expect(await completion.next() == true)
        #expect(await resize.value == 6)
        #expect(cache.contains(key: "page"))
    }

    @MainActor @Test func clearWaitsForOlderWritesAndPreservesFollowingWritesAndDownloads() async throws {
        let root = try makeCacheDirectory()
        let queue = DispatchQueue(label: "ehviewer.test.clear-reader-cache")
        let gate = DispatchSemaphore(value: 0)
        defer {
            gate.signal()
            queue.sync {}
            try? FileManager.default.removeItem(at: root)
        }
        let cacheDir = root.appendingPathComponent("Caches/spider_image", isDirectory: true)
        let download = root.appendingPathComponent("Documents/download", isDirectory: true)
        for directory in [cacheDir, download] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sentinel = download.appendingPathComponent("00000001.png")
        let permanentBytes = Data([8, 7, 6])
        try permanentBytes.write(to: sentinel)
        let cache = SimpleDiskCache(directory: cacheDir, maxSize: 100, queue: queue)
        #expect(cache.set(Data([1]), forKey: "old"))
        let cachedFile = try #require(FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ).first)
        // A symlink entry in Caches must be removed without traversing it.
        try FileManager.default.createSymbolicLink(
            at: cacheDir.appendingPathComponent("fixture-link"), withDestinationURL: download
        )

        let priorWrite = AsyncStream<Bool>.makeStream()
        queue.async {
            do {
                guard gate.wait(timeout: .now() + 5) == .success else {
                    priorWrite.continuation.yield(false)
                    priorWrite.continuation.finish()
                    return
                }
                try Data([2]).write(to: cachedFile)
                priorWrite.continuation.yield(true)
            } catch {
                priorWrite.continuation.yield(false)
            }
            priorWrite.continuation.finish()
        }
        let started = AsyncStream<Void>.makeStream()
        let clear = Task { @MainActor in
            started.continuation.yield()
            started.continuation.finish()
            try await cache.removeAll()
        }
        var running = started.stream.makeAsyncIterator()
        _ = await running.next()
        #expect(FileManager.default.fileExists(atPath: cachedFile.path),
                "An out-of-queue clear would delete this while the earlier write is blocked.")
        gate.signal()
        var result = priorWrite.stream.makeAsyncIterator()
        #expect(await result.next() == true)
        try await clear.value
        #expect(FileManager.default.fileExists(atPath: cacheDir.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).isEmpty)
        #expect(await cache.getDataAsync(forKey: "old") == nil)
        #expect(await cache.setAsync(Data([3]), forKey: "later"))
        #expect(await cache.getDataAsync(forKey: "later") == Data([3]))
        #expect(try Data(contentsOf: sentinel) == permanentBytes)
    }

    @Test func clearRejectsBlockedAndRedirectedCacheRootsWithoutRemovingThem() async throws {
        let root = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let marker = downloads.appendingPathComponent("permanent")
        let payload = Data([6, 5, 4])
        try payload.write(to: marker)
        let blocked = root.appendingPathComponent("blocked")
        try payload.write(to: blocked)
        let redirected = root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: downloads)
        for directory in [blocked, redirected] {
            let cache = SimpleDiskCache(directory: directory, maxSize: 100)
            await #expect(throws: ReaderDiskCacheError.self) {
                try await cache.removeAll()
            }
        }
        #expect(try Data(contentsOf: blocked) == payload)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: redirected.path) == downloads.path)
        #expect(try Data(contentsOf: marker) == payload)
    }

    @Test func clearRecreatesAPurgedDirectoryForLaterWrites() async throws {
        let root = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SimpleDiskCache(directory: root.appendingPathComponent("purged"), maxSize: 100)
        try await cache.removeAll()
        #expect(await cache.setAsync(Data([1]), forKey: "new"))
        #expect(await cache.getDataAsync(forKey: "new") == Data([1]))
    }

    private func makeCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EhReaderDiskCache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
