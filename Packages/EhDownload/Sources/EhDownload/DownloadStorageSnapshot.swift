import Foundation

/// Publishes the row measurements and total together, only for the latest scan.
public struct DownloadStorageSnapshot: Sendable {
    public private(set) var sizes: [Int64: Int64] = [:]
    public private(set) var total: Int64 = 0
    private var pending: UUID?

    public init() {}

    public var isScanning: Bool { pending != nil }

    public mutating func begin() -> UUID {
        let request = UUID()
        pending = request
        return request
    }

    public mutating func finish(_ request: UUID, sizes: [Int64: Int64], total: Int64) {
        guard pending == request else { return }
        self.sizes = sizes
        self.total = total
        pending = nil
    }

    public mutating func cancel(_ request: UUID) {
        guard pending == request else { return }
        pending = nil
    }

    public mutating func remove(gid: Int64, withFiles: Bool) {
        pending = nil // An outstanding scan may still contain the removed row.
        let previous = sizes.removeValue(forKey: gid) ?? 0
        if withFiles { total = max(0, total - previous) }
    }
}
