import Foundation

/// Balances the process-wide flag across readers in separate foreground scenes.
@MainActor
final class ReaderIdleTimerOwnership {
    private var owners: Set<UUID> = []
    private var originalFlag: Bool?
    private let readFlag: @MainActor () -> Bool
    private let writeFlag: @MainActor (Bool) -> Void

    init(readFlag: @escaping @MainActor () -> Bool, writeFlag: @escaping @MainActor (Bool) -> Void) {
        self.readFlag = readFlag
        self.writeFlag = writeFlag
    }

    func update(_ reader: UUID, isVisible: Bool, sceneIsActive: Bool, keepAwake: Bool) {
        if isVisible && sceneIsActive && keepAwake {
            let wasEmpty = owners.isEmpty
            owners.insert(reader)
            if wasEmpty {
                let baseline = readFlag()
                originalFlag = baseline
                if !baseline { writeFlag(true) }
            }
        } else {
            remove(reader)
        }
    }

    func remove(_ reader: UUID) {
        guard owners.remove(reader) != nil, owners.isEmpty, let originalFlag else { return }
        self.originalFlag = nil
        if readFlag() != originalFlag { writeFlag(originalFlag) }
    }
}

#if os(iOS)
import UIKit

extension ReaderIdleTimerOwnership {
    static let shared = ReaderIdleTimerOwnership(
        readFlag: { UIApplication.shared.isIdleTimerDisabled },
        writeFlag: { UIApplication.shared.isIdleTimerDisabled = $0 }
    )
}
#endif
