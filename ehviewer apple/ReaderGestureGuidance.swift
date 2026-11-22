/// Presentation of existing reader controls. Recognition stays in the reader views.
struct ReaderGestureGuidance {
    enum Input { case touch, pointer }

    let direction: ReadingDirection

    var directionTitle: String {
        switch direction {
        case .leftToRight: "左→右"
        case .rightToLeft: "右→左"
        case .topToBottom: "上→下"
        }
    }

    var leftPageTitle: String { direction == .rightToLeft ? "下一页" : "上一页" }
    var rightPageTitle: String { direction == .rightToLeft ? "上一页" : "下一页" }
    var showsDoubleTapZoom: Bool { direction != .topToBottom }

    func motionTitle(for input: Input) -> String {
        if direction == .topToBottom { return "上下滚动阅读" }
        switch input {
        case .touch: return "左右滑动也可以翻页"
        case .pointer: return "使用滚轮或触控板翻页"
        }
    }
}
