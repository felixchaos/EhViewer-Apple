import Testing
@testable import ehviewer_apple

@MainActor
struct ReaderGestureGuidanceTests {
    @Test func verticalGuidanceDescribesScrollingWithoutClaimingDoubleTapZoom() {
        let guidance = ReaderGestureGuidance(direction: .topToBottom)
        #expect(guidance.directionTitle == "上→下")
        #expect(guidance.leftPageTitle == "上一页")
        #expect(guidance.rightPageTitle == "下一页")
        #expect(!guidance.showsDoubleTapZoom)
        #expect(guidance.motionTitle(for: .touch) == "上下滚动阅读")
        #expect(guidance.motionTitle(for: .pointer) == "上下滚动阅读")
    }

    @Test func horizontalGuidanceTracksReadingDirectionAndInput() {
        let leftToRight = ReaderGestureGuidance(direction: .leftToRight)
        let rightToLeft = ReaderGestureGuidance(direction: .rightToLeft)
        #expect(leftToRight.directionTitle == "左→右")
        #expect(rightToLeft.directionTitle == "右→左")
        #expect(leftToRight.leftPageTitle == "上一页")
        #expect(leftToRight.rightPageTitle == "下一页")
        #expect(rightToLeft.leftPageTitle == "下一页")
        #expect(rightToLeft.rightPageTitle == "上一页")
        for guidance in [leftToRight, rightToLeft] {
            #expect(guidance.showsDoubleTapZoom)
            #expect(guidance.motionTitle(for: .touch) == "左右滑动也可以翻页")
            #expect(guidance.motionTitle(for: .pointer) == "使用滚轮或触控板翻页")
        }
    }
}
