import CoreGraphics
import CryptoKit
import EhAPI
import EhCookie
import EhModels
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

nonisolated struct AccountAvatarFiles: Sendable {
    enum ImportError: Error, LocalizedError, Equatable {
        case tooLarge, invalidImage

        var errorDescription: String? {
            switch self {
            case .tooLarge: "头像文件不能超过 20 MB。"
            case .invalidImage: "无法读取此图片。"
            }
        }
    }

    let directory: URL
    private static let maxInputBytes = 20_000_000
    private static let maxOutputEdge = 512

    static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(Self.accountKey(id)).appendingPathExtension("png")
    }

    func load(for id: String) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    func save(_ png: Data, for id: String) throws {
        var localDirectory = directory
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        #endif
        try png.write(to: url(for: id), options: .atomic)
    }

    func reset(for id: String) throws {
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    static func importImage(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let input = try handle.read(upToCount: maxInputBytes + 1) ?? Data()
        return try normalize(input)
    }

    static func normalize(_ input: Data) throws -> Data {
        guard input.count <= maxInputBytes else { throw ImportError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(input as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxOutputEdge
              ] as CFDictionary)
        else { throw ImportError.invalidImage }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportError.invalidImage }
        // Re-encode the pixel data, not the source metadata.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.invalidImage }
        return data as Data
    }
}

@MainActor
@Observable
final class AccountProfileStore {
    enum NameState: Equatable {
        case unavailable, loading, resolved(String), failed
    }

    static let sessionDidChange = Notification.Name("EhAccountSessionDidChange")
    static let shared = makeShared()

    private static func makeShared() -> AccountProfileStore {
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.enabled {
            let env = ProcessInfo.processInfo.environment
            let fixtureName = env["EH_FIXTURE_ACCOUNT_PROFILE"] == "1" ? "Synthetic account" : nil
            return AccountProfileStore(
                defaults: UserDefaults(suiteName: "OfflineAccountProfileFixture") ?? .standard,
                files: AccountAvatarFiles(directory: URL.temporaryDirectory
                    .appendingPathComponent("OfflineAccountAvatars", isDirectory: true)),
                currentMemberID: { fixtureName.map { _ in "970001" } },
                fetchName: { _ in fixtureName }
            )
        }
        #endif
        return AccountProfileStore(
            defaults: .standard,
            files: AccountAvatarFiles(directory: URL.applicationSupportDirectory
                .appendingPathComponent("AccountAvatars", isDirectory: true)),
            currentMemberID: {
                let cookies = EhCookieManager.shared.getCookies(for: EhCookieManager.domainEhentai)
                return memberID(in: cookies)
            },
            fetchName: { id in try await EhAPI.shared.getProfile(expectedMemberID: id).displayName }
        )
    }

    private(set) var memberID: String?
    private(set) var nameState: NameState = .unavailable
    private(set) var avatar: Data?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let files: AccountAvatarFiles
    @ObservationIgnored private let currentMemberID: @MainActor () -> String?
    @ObservationIgnored private let fetchName: @MainActor (String) async throws -> String?
    @ObservationIgnored private var identityEpoch = UUID()
    @ObservationIgnored private var refreshingFor: UUID?

    init(defaults: UserDefaults, files: AccountAvatarFiles,
         currentMemberID: @escaping @MainActor () -> String?,
         fetchName: @escaping @MainActor (String) async throws -> String?) {
        self.defaults = defaults
        self.files = files
        self.currentMemberID = currentMemberID
        self.fetchName = fetchName
        synchronize()
    }

    static func memberID(in cookies: [String: String]) -> String? {
        guard let id = cookies[EhCookieManager.keyIPBMemberId], !id.isEmpty,
              let hash = cookies[EhCookieManager.keyIPBPassHash], !hash.isEmpty else { return nil }
        return id
    }

    var isSignedIn: Bool { memberID != nil }

    var displayTitle: String {
        guard memberID != nil else { return "未登录" }
        switch nameState {
        case .resolved(let name): return name
        case .loading: return "正在读取用户名"
        case .unavailable, .failed: return "用户名不可用"
        }
    }

    func synchronize() {
        updateMember(currentMemberID())
    }

    private func updateMember(_ member: String?) {
        guard memberID != member else { return }
        identityEpoch = UUID()
        refreshingFor = nil
        memberID = member
        nameState = member.flatMap { defaults.string(forKey: storageKey($0)) }
            .map(NameState.resolved) ?? .unavailable
        avatar = member.flatMap { files.load(for: $0) }
    }

    func beginImportedSession() {
        synchronize()
        guard let memberID else { return }
        identityEpoch = UUID()
        refreshingFor = nil
        defaults.removeObject(forKey: storageKey(memberID))
        nameState = .unavailable
        broadcastSessionChange()
    }

    func broadcastSessionChange() {
        NotificationCenter.default.post(name: Self.sessionDidChange, object: nil)
    }

    func rememberLoginName(_ candidate: String?, for id: String) {
        synchronize()
        guard memberID == id, let name = Self.cleanName(candidate) else { return }
        defaults.set(name, forKey: storageKey(id))
        nameState = .resolved(name)
    }

    func refreshName(force: Bool = false) async {
        synchronize()
        guard let memberID, refreshingFor == nil else { return }
        if !force, case .resolved = nameState { return }
        let epoch = identityEpoch
        refreshingFor = epoch
        let hadName: Bool
        if case .resolved = nameState { hadName = true }
        else { hadName = false; nameState = .loading }
        defer {
            if refreshingFor == epoch { refreshingFor = nil }
        }

        do {
            let name = try await fetchName(memberID)
            guard !Task.isCancelled else {
                if identityEpoch == epoch, !hadName { nameState = .unavailable }
                return
            }
            synchronize()
            guard identityEpoch == epoch else { return }
            if Self.cleanName(name) != nil { rememberLoginName(name, for: memberID) }
            else if !hadName { nameState = .failed }
        } catch {
            synchronize()
            if identityEpoch == epoch, !hadName { nameState = Task.isCancelled ? .unavailable : .failed }
        }
    }

    func setAvatar(_ png: Data, for id: String) throws {
        synchronize()
        guard memberID == id else { return }
        try files.save(png, for: id)
        avatar = png
    }

    func resetAvatar(for id: String) throws {
        synchronize()
        guard memberID == id else { return }
        try files.reset(for: id)
        avatar = nil
    }

    func signOut() {
        if let memberID { defaults.removeObject(forKey: storageKey(memberID)) }
        updateMember(nil)
        broadcastSessionChange()
    }

    private func storageKey(_ id: String) -> String {
        "account.loginName.\(AccountAvatarFiles.accountKey(id))"
    }

    private static func cleanName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 200,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }
}
