//
//  EhGalleryRow.swift
//  ehviewer apple
//
//  画廊列表行 — 全 App 唯一的一份
//
//  此前有四套各自的实现：GalleryListView 的 GalleryRow、FavoritesView 的
//  localFavoriteRow、DownloadsView 的 DownloadTaskRow、HistoryView 内联的行。
//  收成一个组件之后仍然出过两类问题，这一版一并堵掉：
//
//  1. 尺寸不一致：首页按响应式基准 × 用户设置的缩放算缩略图，另外三页各自
//     写死常量。同一台 iPhone 上，首页的封面和收藏页的封面不一样大。
//     现在尺寸只在 `resolvedThumbnailSize` 一处算，调用方不再传。
//  2. 信息不一致：调用方各自决定传哪些字段，收藏页只传了标题和封面。
//     现在有 `EhGalleryRow(gallery:)` 这个入口，从 GalleryInfo 一次性铺开
//     所有字段，四个页面都走它，不可能再漏。
//

import SwiftUI
import EhModels
import EhSettings

/// 非泛型：配件用 AnyView 承载。
///
/// 泛型版本在「带配件」与「不带配件」两个构造器之间会产生推断歧义
/// （编译器会把带尾随闭包的调用解析到 Accessory == EmptyView 的那个）。
/// 行右侧的配件只是一个小按钮，AnyView 的开销可以忽略，换来的是调用处干净。
struct EhGalleryRow: View {
    /// 元信息行里的一项。颜色可选，用来区分状态（下载完成绿、失败红）。
    struct MetaItem: Identifiable {
        let text: String
        var color: Color = EhColor.secondaryLabel
        var isMonospaced: Bool = true
        var id: String { text }

        init(_ text: String, color: Color = EhColor.secondaryLabel, isMonospaced: Bool = true) {
            self.text = text
            self.color = color
            self.isMonospaced = isMonospaced
        }
    }

    let cover: String?
    let title: String
    var category: EhCategory? = nil
    var language: String? = nil
    var subtitle: String? = nil          // 上传者 / 相对时间 / 收藏夹备注
    var meta: [MetaItem] = []
    /// 标签 chip
    var tags: [String] = []
    /// 已下载 / 已收藏标记。对齐 Android item_gallery_list.xml 里的
    /// downloaded 与 favourited 两个 16dp ImageView。
    var isDownloaded: Bool = false
    var isFavorited: Bool = false
    var rating: Float? = nil             // nil = 不显示评分
    var trailingText: String? = nil      // 发布时间，跟在星星右侧
    var readProgress: Double? = nil      // 封面底部的阅读进度
    var progress: Double? = nil          // 独立的下载进度条
    var progressLabel: String? = nil
    /// 只有确实需要另一种尺寸的地方才传（目前没有）。默认走统一尺寸。
    var thumbnailSize: CGSize? = nil
    var titleLineLimit: Int = 2

    /// 行右侧的按钮（续读、暂停/重试…）
    var accessory: AnyView? = nil
    /// 点标签 chip 的去向。nil = chip 只是展示，不可点。
    ///
    /// 只有「点了能搜」的页面才传它。收藏、下载、历史三页点标签要跨 Tab
    /// 跳到首页再搜，那是另一件事，不在这一版里。
    var onTagTap: ((String) -> Void)? = nil
    /// 当前搜索命中的标签。这些会排到最前面并高亮——
    /// 搜某个标签时，最想确认的就是「这本是因为哪个标签被搜出来的」。
    var highlightedTags: Set<String> = []

    @Environment(\.responsiveLayout) private var layout

    /// 全 App 统一的缩略图尺寸：响应式基准 × 用户在设置里选的缩放。
    ///
    /// 以前这个式子只在首页的行里有，另外三页传的是 `EhSize.listThumbnail`
    /// 常量，于是设置里把缩略图调大只有首页会变。
    private var resolvedThumbnailSize: CGSize {
        if let thumbnailSize { return thumbnailSize }
        let base = layout.galleryThumbnailSize
        let scale = Self.thumbScale
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    /// 缩略图大小: 0 小 / 1 中 / 2 大
    private static var thumbScale: CGFloat {
        switch AppSettings.shared.thumbSize {
        case 0:  return 0.8
        case 2:  return 1.25
        default: return 1.0
        }
    }

    /// 标签 chip 上的文字：优先中文翻译，没有就去掉命名空间显示裸标签。
    /// 命名空间在 chip 里是噪音——`artist:onion knight kk` 占掉半行，
    /// 而用户扫的是「onion knight kk」这几个字。
    static func tagLabel(_ tag: String) -> String {
        if let zh = EhTagDatabase.shared.getTranslation(tag), zh != tag { return zh }
        guard let colon = tag.firstIndex(of: ":") else { return tag }
        return String(tag[tag.index(after: colon)...])
    }

    /// 标签 chip。可点时用 Button 包起来，并把纵向内边距撑到 6pt——
    /// 10pt 的字加 2pt 内边距只有 14pt 高，手指按不中。
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        let hit = isHighlighted(tag)
        let label = Text(Self.tagLabel(tag))
            .font(.system(size: 10, weight: hit ? .semibold : .regular))
            .foregroundStyle(hit ? EhColor.onAccentFill
                             : (onTagTap == nil ? EhColor.secondaryLabel : EhColor.accent))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, onTagTap == nil ? 2 : 6)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hit ? EhColor.accentFill
                          : (onTagTap == nil ? EhColor.fill : EhColor.accentWash))
            }

        if let onTagTap {
            Button {
                Haptics.tap()
                onTagTap(tag)
            } label: { label }
            // .plain 之外的样式会让 List 把整行的点击也算进来
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// 命中搜索的标签排前面，其余保持原顺序
    private var orderedTags: [String] {
        guard !highlightedTags.isEmpty else { return tags }
        let hit = tags.filter { isHighlighted($0) }
        let rest = tags.filter { !isHighlighted($0) }
        return hit + rest
    }

    /// 标签是否命中当前搜索。比较时去掉命名空间与引号/$，
    /// 因为搜索式里是 `female:"big ass$"`，而 simpleTags 里是 `big ass`。
    private func isHighlighted(_ tag: String) -> Bool {
        guard !highlightedTags.isEmpty else { return false }
        let normalized = Self.normalizeForMatch(tag)
        return highlightedTags.contains { Self.normalizeForMatch($0) == normalized }
    }

    static func normalizeForMatch(_ s: String) -> String {
        var t = s.lowercased()
        if let colon = t.firstIndex(of: ":") { t = String(t[t.index(after: colon)...]) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "\"$ "))
    }

    /// 状态标记要不要占一行
    private var hasStatusRow: Bool { isDownloaded || isFavorited || !meta.isEmpty }

    var body: some View {
        let thumb = resolvedThumbnailSize
        return HStack(alignment: .top, spacing: EhSpacing.row) {
            EhCoverThumbnail(
                url: cover,
                size: thumb,
                category: category,
                language: language,
                readProgress: readProgress
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(EhFont.body)
                    .lineLimit(titleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(EhColor.label)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(EhFont.meta)
                        .foregroundStyle(EhColor.secondaryLabel)
                        .lineLimit(1)
                        .padding(.top, 2)
                }

                // 把元信息压到与封面底边齐平：各行的元信息因此横向成列，
                // 扫视时视线不必逐行重新定位
                Spacer(minLength: 6)

                if !tags.isEmpty {
                    // 一行，但可以横向滑到后面的标签。
                    //
                    // 此前是 `tags.prefix(4)` 直接截断：多出来的标签既看不到、
                    // 也没有任何办法看到。列表行确实不该被标签占满，但「放不下」
                    // 和「不给看」是两回事。
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(orderedTags, id: \.self) { tag in
                                tagChip(tag)
                            }
                        }
                        // 让最后一枚 chip 也能滑到视野中央，不贴着边
                        .padding(.trailing, 8)
                    }
                    // 横向滚动区不能吃掉列表的纵向滑动
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .padding(.bottom, 4)
                }

                // 状态标记这一行此前被写在 `if !meta.isEmpty` 里面：
                // 元信息为空的页面（收藏、历史）永远看不到已下载/已收藏，
                // 首页在关掉「显示页数」后也一样看不到。现在它自己成一行。
                if hasStatusRow {
                    HStack(spacing: EhSpacing.meta) {
                        if isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(EhColor.success)
                        }
                        if isFavorited {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(EhColor.danger)
                        }
                        ForEach(meta) { item in
                            Text(item.text)
                                .font(item.isMonospaced
                                      ? EhFont.mono(11)
                                      : .system(size: 11, weight: .semibold))
                                .foregroundStyle(item.color)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if let progress {
                    HStack(spacing: EhSpacing.meta) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(EhColor.fill)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(EhColor.accentFill)
                                    .frame(width: geo.size.width * max(0, min(1, progress)))
                            }
                        }
                        .frame(height: 3)

                        if let progressLabel {
                            Text(progressLabel)
                                .font(EhFont.mono(11, weight: .medium))
                                .foregroundStyle(EhColor.accent)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    .padding(.top, 5)
                }

                if let rating {
                    EhRatingRow(rating: rating, trailingText: trailingText)
                        .padding(.top, 5)
                } else if let trailingText, !trailingText.isEmpty {
                    Text(trailingText)
                        .font(EhFont.mono(11))
                        .foregroundStyle(EhColor.tertiaryLabel)
                        .padding(.top, 5)
                }
            }
            .frame(minHeight: thumb.height, alignment: .top)

            accessory
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.vertical, 10)
        // 行高按内容决定，不跟着父容器拉伸。
        // 内部那个撑开元信息的 Spacer 是贪心的，放进非 List 的 VStack
        // （收藏页的「本地收藏」区块）里会把整行拉成半屏高。
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
}

// MARK: - 从 GalleryInfo 一次性铺开

extension EhGalleryRow {
    /// 全 App 四个列表页的唯一入口。
    ///
    /// 字段在这里一次性铺开，调用方不再各自挑着传——收藏页只传标题和封面、
    /// 历史页丢掉评分和语言这类事，就是从「调用方自己决定传什么」来的。
    init(
        gallery: GalleryInfo,
        subtitleOverride: String? = nil,
        extraMeta: [MetaItem] = [],
        /// 调用方自己的 meta 里已经含总页数时置 true（下载中的「12/50」）
        hidesPageCount: Bool = false,
        progress: Double? = nil,
        progressLabel: String? = nil,
        accessory: AnyView? = nil,
        onTagTap: ((String) -> Void)? = nil,
        highlightedTags: Set<String> = []
    ) {
        let settings = AppSettings.shared
        var meta = extraMeta
        if settings.showGalleryPages, gallery.pages > 0, !hidesPageCount {
            meta.append(.init("\(gallery.pages)P"))
        }
        if settings.showReadProgress, gallery.pages > 0 {
            let index = UserDefaults.standard.integer(forKey: "reading_progress_\(gallery.gid)")
            if index > 0 {
                meta.append(.init("读至 \(index + 1)", color: EhColor.accent))
            }
        }

        self.init(
            cover: gallery.thumb,
            title: gallery.suitableTitle(preferJpn: settings.showJpnTitle),
            category: gallery.category,
            language: gallery.simpleLanguage,
            subtitle: subtitleOverride ?? gallery.uploader,
            meta: meta,
            tags: gallery.simpleTags ?? [],
            isDownloaded: GalleryStatusCache.shared.isDownloaded(gid: gallery.gid),
            isFavorited: GalleryStatusCache.shared.isFavorited(gallery),
            rating: settings.showGalleryRating ? gallery.rating : nil,
            trailingText: gallery.posted,
            progress: progress,
            progressLabel: progressLabel,
            accessory: accessory,
            onTagTap: onTagTap,
            highlightedTags: highlightedTags
        )
    }
}

/// 行右侧的圆形动作按钮（续读、暂停、重试）
struct EhRowActionButton: View {
    let symbol: String
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.37, weight: .bold))
                .foregroundStyle(EhColor.accent)
                .frame(width: size, height: size)
                .background(Circle().fill(EhColor.fill))
        }
        .buttonStyle(.plain)
    }
}
