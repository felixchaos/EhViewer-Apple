import Darwin
import Foundation
import zlib

/// Narrow ZIP32 reader for imported galleries. No entry name is ever used as
/// an output path. Each local record, central record, size and CRC must agree.
final class OfflineGalleryZIP {
    struct Entry {
        let name: String
        let bytes: [UInt8]
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
        let directory: Bool
        var dataStart = 0
    }

    private static let maxArchiveBytes = 1_000_000_000
    private static let maxCentralBytes = 16_000_000
    private static let maxEntries = 4_096
    private static let bufferSize = 64 * 1_024
    private let fd: Int32
    private let length: Int

    init(_ url: URL) throws {
        let handle = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard handle >= 0 else { throw OfflineGalleryImportError.unsafeFile }
        var details = stat()
        guard fstat(handle, &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(handle)
            throw OfflineGalleryImportError.unsafeFile
        }
        guard details.st_size <= Self.maxArchiveBytes else {
            Darwin.close(handle)
            throw OfflineGalleryImportError.tooLarge
        }
        fd = handle
        length = Int(details.st_size)
    }

    deinit { Darwin.close(fd) }

    func entries(maxEntryBytes: Int, maxExpandedBytes: Int) throws -> [Entry] {
        try Task.checkCancellation()
        let tailOffset = max(0, length - 22 - 65_535)
        let tail = try read(tailOffset, length - tailOffset)
        guard tail.count >= 22 else { throw OfflineGalleryImportError.invalidArchive }
        // An EOCD signature in the archive comment is ambiguous. Refuse multiple
        // candidates instead of guessing which metadata controls the bytes.
        let endRecords = (0...(tail.count - 22)).filter {
            tail.u32($0) == 0x06054b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }
        guard endRecords.count == 1, let end = endRecords.first else {
            throw OfflineGalleryImportError.invalidArchive
        }
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10)
        else { throw OfflineGalleryImportError.unsupportedArchive }
        let count = Int(tail.u16(end + 10))
        let size = Int(tail.u32(end + 12))
        let start = Int(tail.u32(end + 16))
        guard count != 0xffff, size != 0xffffffff, start != 0xffffffff
        else { throw OfflineGalleryImportError.unsupportedArchive }
        guard count <= Self.maxEntries, size <= Self.maxCentralBytes else { throw OfflineGalleryImportError.tooLarge }
        guard start + size == tailOffset + end else { throw OfflineGalleryImportError.invalidArchive }
        let catalog = try read(start, size)
        var cursor = 0
        var total = 0
        var all: [Entry] = []
        var names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard catalog.count - cursor >= 46, catalog.u32(cursor) == 0x02014b50
            else { throw OfflineGalleryImportError.invalidArchive }
            let needed = catalog.u16(cursor + 6)
            let flags = catalog.u16(cursor + 8)
            let method = catalog.u16(cursor + 10)
            let crc = catalog.u32(cursor + 16)
            let compressed = Int(catalog.u32(cursor + 20))
            let expanded = Int(catalog.u32(cursor + 24))
            let nameCount = Int(catalog.u16(cursor + 28))
            let extra = Int(catalog.u16(cursor + 30))
            let comment = Int(catalog.u16(cursor + 32))
            let attributes = catalog.u32(cursor + 38)
            let local = Int(catalog.u32(cursor + 42))
            guard needed <= 20, catalog.u16(cursor + 34) == 0, flags & ~0x080e == 0,
                  (method == 8 || (method == 0 && flags & 0x0006 == 0)),
                  compressed != 0xffffffff, expanded != 0xffffffff, local != 0xffffffff
            else { throw OfflineGalleryImportError.unsupportedArchive }
            let nameStart = cursor + 46
            let extraStart = nameStart + nameCount
            let next = extraStart + extra + comment
            guard nameCount > 0, nameCount <= 1024, next <= catalog.count else {
                throw OfflineGalleryImportError.invalidArchive
            }
            try Self.checkExtra(catalog, from: extraStart, size: extra)
            let bytes = Array(catalog[nameStart..<extraStart])
            guard let name = String(bytes: bytes, encoding: .utf8),
                  !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw OfflineGalleryImportError.unsafeFile }
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.count <= 32, components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            }), names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted
            else { throw OfflineGalleryImportError.unsafeFile }
            let unixKind = (attributes >> 16) & 0xf000
            guard (unixKind == 0 || unixKind == (directory ? 0x4000 : 0x8000)),
                  (attributes & 0x10 == 0 || directory), attributes & 0x400 == 0
            else { throw OfflineGalleryImportError.unsafeFile }
            guard expanded <= maxEntryBytes, expanded <= maxExpandedBytes - total
            else { throw OfflineGalleryImportError.tooLarge }
            guard (method != 0 || compressed == expanded), !directory || expanded == 0
            else { throw OfflineGalleryImportError.invalidArchive }
            total += expanded
            all.append(Entry(name: name, bytes: bytes, flags: flags, method: method, crc: crc,
                             compressed: compressed, expanded: expanded, offset: local, directory: directory))
            cursor = next
        }
        guard cursor == catalog.count else { throw OfflineGalleryImportError.invalidArchive }

        // Require each distinct local record to be completely accounted for and
        // non-overlapping. No prepended executable, unused gap, or hidden stream.
        all.sort { $0.offset < $1.offset }
        var expected = 0
        for i in all.indices {
            try Task.checkCancellation()
            var entry = all[i]
            let end = i + 1 < all.count ? all[i + 1].offset : start
            guard entry.offset == expected, entry.offset <= end, end <= start, end - entry.offset >= 30
            else { throw OfflineGalleryImportError.invalidArchive }
            let local = try read(entry.offset, 30)
            guard local.u32(0) == 0x04034b50, local.u16(4) <= 20,
                  local.u16(6) == entry.flags, local.u16(8) == entry.method
            else { throw OfflineGalleryImportError.invalidArchive }
            let nameLength = Int(local.u16(26))
            let extraLength = Int(local.u16(28))
            let variableSize = nameLength + extraLength
            let dataStart = entry.offset + 30 + variableSize
            guard nameLength == entry.bytes.count, dataStart <= end, entry.compressed <= end - dataStart
            else { throw OfflineGalleryImportError.invalidArchive }
            let variable = try read(entry.offset + 30, variableSize)
            guard variable.prefix(nameLength).elementsEqual(entry.bytes)
            else { throw OfflineGalleryImportError.invalidArchive }
            try Self.checkExtra(variable, from: nameLength, size: extraLength)
            let after = dataStart + entry.compressed
            if entry.flags & 8 != 0 {
                guard (local.u32(14) == 0 || local.u32(14) == entry.crc),
                      (local.u32(18) == 0 || Int(local.u32(18)) == entry.compressed),
                      (local.u32(22) == 0 || Int(local.u32(22)) == entry.expanded),
                      end - after == 12 || end - after == 16
                else { throw OfflineGalleryImportError.invalidArchive }
                let descriptor = try read(after, end - after)
                let field = descriptor.count - 12
                guard (field == 0 || descriptor.u32(0) == 0x08074b50),
                      descriptor.u32(field) == entry.crc,
                      Int(descriptor.u32(field + 4)) == entry.compressed,
                      Int(descriptor.u32(field + 8)) == entry.expanded
                else { throw OfflineGalleryImportError.invalidArchive }
            } else {
                guard end == after, local.u32(14) == entry.crc,
                      Int(local.u32(18)) == entry.compressed, Int(local.u32(22)) == entry.expanded
                else { throw OfflineGalleryImportError.invalidArchive }
            }
            entry.dataStart = dataStart
            all[i] = entry
            expected = end
        }
        guard expected == start else { throw OfflineGalleryImportError.invalidArchive }
        return all
    }

    /// Verify and stream a payload; files not imported are still CRC-checked.
    func stream(_ entry: Entry, writingTo output: FileHandle?) throws {
        var crc = crc32(0, nil, 0)
        var size = 0
        var consumed = 0
        func emit(_ bytes: UnsafePointer<UInt8>, _ count: Int) throws {
            guard count <= entry.expanded - size else { throw OfflineGalleryImportError.invalidArchive }
            if count == 0 { return }
            size += count
            crc = crc32(crc, bytes, UInt32(count))
            if let output { try output.write(contentsOf: Data(bytes: bytes, count: count)) }
        }

        if entry.method == 0 {
            while consumed < entry.compressed {
                try Task.checkCancellation()
                let amount = min(Self.bufferSize, entry.compressed - consumed)
                let input = try read(entry.dataStart + consumed, amount)
                try input.withUnsafeBufferPointer { try emit($0.baseAddress!, amount) }
                consumed += amount
            }
        } else {
            var state = z_stream()
            guard inflateInit2_(&state, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
            else { throw OfflineGalleryImportError.invalidArchive }
            defer { inflateEnd(&state) }
            var ended = false
            var output = [UInt8](repeating: 0, count: Self.bufferSize)
            while consumed < entry.compressed && !ended {
                try Task.checkCancellation()
                let amount = min(Self.bufferSize, entry.compressed - consumed)
                var input = try read(entry.dataStart + consumed, amount)
                try input.withUnsafeMutableBufferPointer { pointer in
                    state.next_in = pointer.baseAddress
                    state.avail_in = UInt32(amount)
                    while true {
                        try Task.checkCancellation()
                        let previous = state.avail_in
                        let status = try output.withUnsafeMutableBufferPointer { buffer in
                            state.next_out = buffer.baseAddress
                            state.avail_out = UInt32(Self.bufferSize)
                            let status = inflate(&state, Z_NO_FLUSH)
                            try emit(buffer.baseAddress!, Self.bufferSize - Int(state.avail_out))
                            return status
                        }
                        if status == Z_STREAM_END {
                            guard state.avail_in == 0 else { throw OfflineGalleryImportError.invalidArchive }
                            ended = true
                            break
                        }
                        let progressed = previous != state.avail_in || state.avail_out != UInt32(Self.bufferSize)
                        if status == Z_BUF_ERROR && state.avail_in == 0 { break }
                        guard status == Z_OK, progressed else { throw OfflineGalleryImportError.invalidArchive }
                        if state.avail_in == 0, state.avail_out > 0 { break }
                    }
                }
                consumed += amount
            }
            guard ended, consumed == entry.compressed else { throw OfflineGalleryImportError.invalidArchive }
        }
        guard size == entry.expanded, crc == UInt(entry.crc) else { throw OfflineGalleryImportError.invalidArchive }
    }

    private func read(_ offset: Int, _ count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset <= length, count <= length - offset
        else { throw OfflineGalleryImportError.invalidArchive }
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var readCount = 0
            while readCount < count {
                let result = pread(fd, buffer.baseAddress!.advanced(by: readCount), count - readCount, off_t(offset + readCount))
                if result == -1 && errno == EINTR { continue }
                guard result > 0 else { throw OfflineGalleryImportError.invalidArchive }
                readCount += result
            }
        }
        return bytes
    }

    private static func checkExtra(_ bytes: [UInt8], from start: Int, size: Int) throws {
        var offset = start
        let end = start + size
        while offset < end {
            guard end - offset >= 4 else { throw OfflineGalleryImportError.invalidArchive }
            let tag = bytes.u16(offset)
            guard tag != 1 else { throw OfflineGalleryImportError.unsupportedArchive }
            offset += 4 + Int(bytes.u16(offset + 2))
            guard offset <= end else { throw OfflineGalleryImportError.invalidArchive }
        }
    }
}

private extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | (UInt16(self[i + 1]) << 8) }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | (UInt32(u16(i + 2)) << 16) }
}
