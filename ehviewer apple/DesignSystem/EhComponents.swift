//
//  EhComponents.swift
//  ehviewer apple
//
//  设计系统 — 复用组件
//
//  这一层只做呈现，不持有业务状态：所有数据经参数传入，所有交互经闭包回调。
//  这样同一个组件能同时服务列表、收藏、下载、历史几处，改样式只改一个地方。
//

import SwiftUI
import EhModels

// MARK: - 封面

/// 带分类色条的封面缩略图。
///
/// 分类色从列表内的彩色方块改为封面左侧 3px 色条——方块在深色底上过于抢眼，
/// 而色条既保留了分类的可扫视性，又不与内容争夺注意力。
struct EhCoverThumbnail: View {
    let url: String?
    let size: CGSize
    /// 传 nil 则不显示色条（历史、下载等不需要分类的场合）
    var category: EhCategory? = nil
    var cornerRadius: CGFloat = EhRadius.thumbnail
    /// 0...1，显示在底部的阅读进度；nil 表示不显示
    var readProgress: Double? = nil

    var body: some View {
        HStack(spacing: 0) {
            if let category {
                Rectangle()
                    .fill(category.color)
                    .frame(width: EhSize.categoryBarWidth)
            }

            CachedAsyncImage(url: URL(string: url ?? ""), showProgress: false) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                EhColor.thumbnailPlaceholder
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .bottom) {
                if let readProgress {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(EhColor.accentFill)
                            .frame(
                                width: geo.size.width * max(0, min(1, readProgress)),
                                height: EhSize.progressBarHeight
                            )
                    }
                    .frame(height: EhSize.progressBarHeight)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 评分

/// 数值 + 细色条的评分呈现，取代五颗星。
///
/// 五颗星在 15px 的行高里只能画得很小，且半星难以辨认；数值加一条 2px 的条
/// 既精确又省空间。是否显示由 `AppSettings.showGalleryRating` 控制。
struct EhRatingRow: View {
    /// GalleryInfo.rating 是 Float，这里统一收成 Double 由构造器转换
    let rating: Double
    /// 右侧附加文字（发布时间等）
    var trailingText: String? = nil
    var barWidth: CGFloat = 92

    init(rating: Double, trailingText: String? = nil, barWidth: CGFloat = 92) {
        self.rating = rating
        self.trailingText = trailingText
        self.barWidth = barWidth
    }

    init(rating: Float, trailingText: String? = nil, barWidth: CGFloat = 92) {
        self.init(rating: Double(rating), trailingText: trailingText, barWidth: barWidth)
    }

    var body: some View {
        HStack(spacing: EhSpacing.meta) {
            Text(String(format: "%.2f", rating))
                .font(EhFont.mono(13, weight: .semibold))
                .foregroundStyle(EhColor.accent)

            ZStack(alignment: .leading) {
                Capsule().fill(EhColor.fill)
                Capsule()
                    .fill(EhColor.accentFill)
                    .frame(width: barWidth * max(0, min(1, rating / 5)))
            }
            .frame(width: barWidth, height: EhSize.ratingBarHeight)

            if let trailingText {
                Spacer(minLength: 4)
                Text(trailingText)
                    .font(EhFont.mono(11))
                    .foregroundStyle(EhColor.tertiaryLabel)
            }
        }
    }
}

// MARK: - 顶部横向切页

/// 首页/订阅/热门/排行 的横向切页，选中项带 2px 琥珀下划线。
///
/// 取代原先「更多」标签页里的二级跳转：这四者是同一类内容的不同数据源，
/// 放在同一层级横向切换比藏进二级菜单更符合它们的关系。
struct EhTopTabs<T: Hashable>: View {
    let items: [(value: T, title: String)]
    @Binding var selection: T

    @Namespace private var underline

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(items, id: \.value) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { selection = item.value }
                    } label: {
                        VStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 15, weight: selection == item.value ? .semibold : .regular))
                                .foregroundStyle(selection == item.value ? EhColor.label : EhColor.secondaryLabel)

                            Group {
                                if selection == item.value {
                                    Capsule()
                                        .fill(EhColor.accentFill)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, EhSpacing.page)
        }
        .frame(height: 36)
    }
}

// MARK: - 胶囊过滤器

/// 横向滚动的胶囊过滤条（下载状态、收藏夹、排行榜周期等）
struct EhFilterPills<T: Hashable>: View {
    let items: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.value) { item in
                    let isSelected = selection == item.value
                    Button {
                        selection = item.value
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? EhColor.onAccentFill : EhColor.secondaryLabel)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background {
                                Capsule().fill(isSelected ? EhColor.accentFill : EhColor.fill)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, EhSpacing.page)
        }
        .frame(height: 46)
    }
}

// MARK: - 分段控件

/// 琥珀填充的分段控件，用于阅读方向、主题、排行周期等互斥选项
struct EhSegmented<T: Hashable>: View {
    let items: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.value) { item in
                let isSelected = selection == item.value
                Button {
                    selection = item.value
                } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? EhColor.onAccentFill : EhColor.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            RoundedRectangle(cornerRadius: EhRadius.smallControl, style: .continuous)
                                .fill(isSelected ? EhColor.accentFill : EhColor.fill)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 空态与错误态

/// 统一的空态 / 错误态。
///
/// 错误态优先于空态：加载失败时列表也是空的，但此时该显示的是「重试」而不是
/// 「去搜点什么」——把用户往错误的方向引导比不引导更糟。
struct EhStateView: View {
    enum Kind {
        case empty(symbol: String, title: String, message: String)
        case error(title: String, message: String)
    }

    let kind: Kind
    var primaryAction: (title: String, action: () -> Void)? = nil
    var secondaryAction: (title: String, action: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isError ? EhColor.danger : EhColor.tertiaryLabel)

            VStack(spacing: 6) {
                Text(title)
                    .font(EhFont.title)
                    .foregroundStyle(EhColor.label)
                Text(message)
                    .font(EhFont.caption)
                    .foregroundStyle(EhColor.secondaryLabel)
                    .multilineTextAlignment(.center)
            }

            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: 10) {
                    if let primaryAction {
                        Button(primaryAction.title, action: primaryAction.action)
                            .buttonStyle(EhFilledButtonStyle())
                    }
                    if let secondaryAction {
                        Button(secondaryAction.title, action: secondaryAction.action)
                            .buttonStyle(EhTintedButtonStyle())
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isError: Bool { if case .error = kind { return true }; return false }

    private var symbolName: String {
        switch kind {
        case .empty(let symbol, _, _): return symbol
        case .error: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch kind {
        case .empty(_, let t, _), .error(let t, _): return t
        }
    }

    private var message: String {
        switch kind {
        case .empty(_, _, let m), .error(_, let m): return m
        }
    }
}

// MARK: - 按钮样式

/// 琥珀填充的主按钮
struct EhFilledButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EhFont.button)
            .foregroundStyle(EhColor.onAccentFill)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: EhRadius.control, style: .continuous)
                    .fill(EhColor.accentFill)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// 弱填充的次按钮
struct EhTintedButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EhFont.button)
            .foregroundStyle(EhColor.label)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: EhRadius.control, style: .continuous)
                    .fill(EhColor.fill)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// 详情页操作区的方形图标按钮
struct EhSquareIconButton: View {
    let symbol: String
    var tint: Color = EhColor.label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: EhSize.actionSquareButton, height: EhSize.actionSquareButton)
                .background {
                    RoundedRectangle(cornerRadius: EhRadius.control, style: .continuous)
                        .fill(EhColor.fill)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 行分隔

/// 列表行之间的 hairline。用它而不是系统 List 分隔线，
/// 因为系统分隔线的缩进与颜色都无法对齐设计稿。
struct EhHairline: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(EhColor.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}
