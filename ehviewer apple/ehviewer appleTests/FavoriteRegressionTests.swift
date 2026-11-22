import Combine
import Foundation
import SwiftUI
import Testing
import EhModels
#if os(iOS)
import UIKit
#endif
@testable import ehviewer_apple

@MainActor
@Suite(.serialized)
struct FavoriteRegressionTests {
    @Test(arguments: [false, true])
    func delayedCloudSuccessCannotPublishIntoANewerContext(backToOriginalSite: Bool) async {
        let old = CloudFavoriteContext(generation: UUID(), siteID: 0)
        var current = old
        var badgeSlot = 4
        var cachedDetailSlot = 4
        var requests = 0

        do {
            try await old.perform(current: { current }, request: {
                requests += 1
                await withCheckedContinuation { (response: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        current = CloudFavoriteContext(generation: UUID(), siteID: 1)
                        if backToOriginalSite {
                            current = CloudFavoriteContext(generation: UUID(), siteID: 0)
                        }
                        badgeSlot = -1
                        cachedDetailSlot = -1
                        response.resume()
                    }
                }
            }, commit: {
                badgeSlot = 2
                cachedDetailSlot = 2
            })
            Issue.record("A successful old request must not publish into the current cache")
        } catch is CloudFavoriteContext.Superseded {
            // The test models only the local commit; the old remote response succeeded.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(requests == 1)
        #expect(badgeSlot == -1)
        #expect(cachedDetailSlot == -1)
    }

    @Test func supersededBatchItemDoesNotSendWhileCurrentItemPublishes() async throws {
        let previous = CloudFavoriteContext(generation: UUID(), siteID: 0)
        let current = CloudFavoriteContext(generation: UUID(), siteID: 0)
        var requests = 0
        var commits = 0
        do {
            try await previous.perform(current: { current }, request: { requests += 1 }, commit: { commits += 1 })
            Issue.record("An invalidated batch must not start another request")
        } catch is CloudFavoriteContext.Superseded {
            // Remaining rows from the old selection should never be submitted.
        }
        #expect(requests == 0 && commits == 0)
        try await current.perform(current: { current }, request: { requests += 1 }, commit: { commits += 1 })
        #expect(requests == 1 && commits == 1)
    }

    @Test func warmAndColdDetailsUseLiveLocalState() async {
        let gid: Int64 = -189321
        defer { GalleryCache.shared.removeDetail(gid: gid) }
        let synthetic = GalleryDetail(info: GalleryInfo(gid: gid, token: "unused"))
        var savedLocal = true
        var calls = 0
        let vm = GalleryDetailViewModel()
        await vm.loadDetail(gid: gid, token: "unused", fetchDetail: { _ in calls += 1; return synthetic },
                            readLocalFavorite: { savedLocal })
        #expect(vm.isFavorited)
        #expect(vm.favoriteState.local && !vm.favoriteState.cloud)
        #expect(calls == 1)

        vm.reset()
        await vm.loadDetail(gid: gid, token: "unused", fetchDetail: { _ in calls += 1; return synthetic },
                            readLocalFavorite: { savedLocal })
        #expect(vm.isFavorited)
        #expect(calls == 1)

        savedLocal = false
        vm.reset()
        await vm.loadDetail(gid: gid, token: "unused", fetchDetail: { _ in calls += 1; return synthetic },
                            readLocalFavorite: { savedLocal })
        #expect(!vm.isFavorited)
        #expect(calls == 1)
    }

    @Test func cachedCloudAndLocalStateAreIndependent() async {
        let gid: Int64 = -189322
        defer {
            GalleryCache.shared.removeDetail(gid: gid)
            GalleryStatusCache.shared.resetCloudState()
        }
        GalleryCache.shared.putDetail(GalleryDetail(info: GalleryInfo(gid: gid, token: "unused"),
                                                    isFavorited: true))
        let vm = GalleryDetailViewModel()
        await vm.loadDetail(gid: gid, token: "unused", fetchDetail: { _ in
            Issue.record("Cached detail unexpectedly fetched")
            return GalleryDetail()
        }, readLocalFavorite: { true })
        #expect(vm.favoriteState.local && vm.favoriteState.cloud)
        vm.favoriteDidChange(local: false, cloudSlot: nil)
        #expect(vm.isFavorited)
        GalleryActionService.shared.recordCloudFavorite(gid: gid, slot: -1)
        vm.favoriteDidChange(local: nil, cloudSlot: -1)
        #expect(!vm.isFavorited)
        #expect(GalleryCache.shared.getDetail(gid: gid)?.isFavorited == false)
    }

    @Test func cloudMutationUpdatesHomeAndRemovesDepartedCategoryRows() {
        let gid: Int64 = -189323
        let item = GalleryInfo(gid: gid, token: "unused", favoriteSlot: 1)
        let home = GalleryListViewModel(filterGalleries: { _ in 0 })
        let category = GalleryListViewModel(filterGalleries: { _ in 0 })
        home.galleries = [item]
        category.galleries = [item]
        home.applyCloudFavoriteChange(gid: gid, slot: 2, mode: .home)
        category.applyCloudFavoriteChange(gid: gid, slot: 2, mode: .favorites(slot: 1))
        #expect(home.galleries.first?.favoriteSlot == 2)
        #expect(category.galleries.isEmpty)
    }

    @Test func localRemovalNeverCallsCloudAndFailureDoesNotFallThrough() async throws {
        var localCalls = 0
        var cloudCalls = 0
        enum FixtureError: Error { case local }
        let result = try await GalleryActionService.removePreferredFavorite(
            readLocal: { true }, removeLocal: { localCalls += 1 }, removeCloud: { cloudCalls += 1 })
        #expect(result == .local && localCalls == 1 && cloudCalls == 0)
        do {
            _ = try await GalleryActionService.removePreferredFavorite(
                readLocal: { true }, removeLocal: { throw FixtureError.local }, removeCloud: { cloudCalls += 1 })
            Issue.record("Failed local removal succeeded")
        } catch {}
        #expect(cloudCalls == 0)
        let cloudResult = try await GalleryActionService.removePreferredFavorite(
            readLocal: { false }, removeLocal: { localCalls += 1 }, removeCloud: { cloudCalls += 1 })
        #expect(cloudResult == .cloud && localCalls == 1 && cloudCalls == 1)
    }
}

#if os(iOS)
@MainActor private final class HeaderProbe: ObservableObject {
    @Published var width: CGFloat = 300
    @Published var populated = false
    var top: CGFloat?
}

@MainActor private struct HeaderFixture: View {
    @ObservedObject var probe: HeaderProbe
    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 0) {
                EhPageHeader(title: "Fixture")
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("viewport")).minY } action: {
                        probe.top = $0
                    }
                if probe.populated { Color.gray.frame(height: 90) }
            }
            .ehPageSearch(isActive: .constant(false), text: .constant(""), placeholder: "Fixture")
        }
        .frame(width: probe.width, height: 360)
        .coordinateSpace(name: "viewport")
    }
}

@MainActor
struct FavoriteHeaderRegressionTests {
    @Test func sharedPageHeaderDoesNotCenterAsContentOrWidthChanges() async throws {
        let probe = HeaderProbe()
        let host = UIHostingController(rootView: HeaderFixture(probe: probe))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for populated in [false, true, false] {
            probe.width = populated ? 600 : 300
            probe.populated = populated
            for _ in 0..<8 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(abs((probe.top ?? -100) - 0) < 1)
        }
    }
}
#endif
