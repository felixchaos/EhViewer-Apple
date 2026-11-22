import Foundation

/// A cloud favorite operation belongs to both a site and a cache generation.
/// The generation prevents an old operation from appearing current after A → B → A.
struct CloudFavoriteContext: Equatable {
    let generation: UUID
    let siteID: Int

    enum Superseded: Error { case contextChanged }

    func perform(
        current: () -> Self,
        request: () async throws -> Void,
        commit: () -> Void
    ) async throws {
        guard self == current() else { throw Superseded.contextChanged }
        do {
            try await request()
        } catch {
            guard self == current() else { throw Superseded.contextChanged }
            throw error
        }
        // Guard local effects; a request already dispatched may still succeed remotely.
        guard self == current() else { throw Superseded.contextChanged }
        commit()
    }
}
