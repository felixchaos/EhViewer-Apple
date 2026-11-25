import EhCookie
import Foundation
import ImageIO
import Testing
@testable import ehviewer_apple

@MainActor
struct AccountProfileStoreTests {
    private final class Session {
        var member: String?
        var response: String?
        var failure = false
    }

    @Test func requiresBothNonemptyAuthenticationCookies() {
        let id = EhCookieManager.keyIPBMemberId
        let hash = EhCookieManager.keyIPBPassHash
        #expect(AccountProfileStore.memberID(in: [:]) == nil)
        #expect(AccountProfileStore.memberID(in: [id: "52"]) == nil)
        #expect(AccountProfileStore.memberID(in: [id: "52", hash: ""]) == nil)
        #expect(AccountProfileStore.memberID(in: [id: "52", hash: "fixture"]) == "52")
    }

    @Test func resolvesCookieUsernameWithoutBorrowingAnotherAccountsData() async throws {
        let suite = "AccountProfileStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let session = Session()
        let files = AccountAvatarFiles(directory: directory)
        let profile = AccountProfileStore(defaults: defaults, files: files,
                                          currentMemberID: { session.member },
                                          fetchName: { _ in session.response })
        #expect(!profile.isSignedIn)
        #expect(profile.displayTitle == "未登录")

        session.member = "52"
        profile.synchronize()
        profile.rememberLoginName("  login-a  ", for: "52")
        let png = try AccountAvatarFiles.normalize(Self.samplePNG)
        try profile.setAvatar(png, for: "52")
        #expect(profile.nameState == .resolved("login-a"))
        #expect(profile.avatar == png)

        session.member = "53"
        profile.beginImportedSession()
        #expect(profile.avatar == nil)
        #expect(profile.nameState == .unavailable)
        session.response = "account-b"
        await profile.refreshName()
        #expect(profile.nameState == .resolved("account-b"))

        // A delayed editor belonging to account A cannot write account B.
        try profile.setAvatar(png, for: "52")
        #expect(profile.avatar == nil)

        session.member = "52"
        profile.synchronize()
        #expect(profile.avatar == png)
        #expect(profile.nameState == .resolved("login-a"))
        try profile.resetAvatar(for: "52")
        #expect(files.load(for: "52") == nil)

        session.member = nil
        profile.signOut()
        #expect(!profile.isSignedIn)
        #expect(profile.displayTitle == "未登录")
    }

    @Test func aLateLookupCannotPublishAcrossAccounts() async throws {
        let suite = "AccountProfileLookupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = Session()
        session.member = "52"
        let mock = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let local = AccountProfileStore(
            defaults: defaults,
            files: AccountAvatarFiles(directory: URL.temporaryDirectory.appendingPathComponent(suite)),
            currentMemberID: { session.member }
        ) { id in
            if id == "52" {
                started.continuation.yield(())
                for await _ in mock.stream { break }
                return "old"
            }
            throw URLError(.userAuthenticationRequired)
        }
        let lookup = Task { await local.refreshName() }
        var iter = started.stream.makeAsyncIterator()
        _ = await iter.next()
        session.member = "53"
        local.beginImportedSession()
        await local.refreshName()
        mock.continuation.yield(())
        await lookup.value
        #expect(local.memberID == "53")
        #expect(local.nameState == .failed)
        #expect(local.displayTitle == "用户名不可用")
    }

    @Test func convertsValidImageAndRejectsInvalidOrOversizedInput() throws {
        let png = try AccountAvatarFiles.normalize(Self.samplePNG)
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetCount(image) == 1)
        #expect(throws: AccountAvatarFiles.ImportError.invalidImage) {
            try AccountAvatarFiles.normalize(Data([0, 1, 2]))
        }
        #expect(throws: AccountAvatarFiles.ImportError.tooLarge) {
            try AccountAvatarFiles.normalize(Data(repeating: 0, count: 20_000_001))
        }
    }

    private static let samplePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
}
