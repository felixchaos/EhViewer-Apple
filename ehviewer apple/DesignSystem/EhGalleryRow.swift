//
//  EhGalleryRow.swift
//  ehviewer apple
//
//  画廊列表行 — 全 App 唯一的一份
//
//  此前有四套各自的实现：GalleryListView 的 GalleryRow、FavoritesView 的
//  localFavoriteRow、DownloadsView 的 DownloadTaskRow、HistoryView 内联的行。
//  同一件事写四遍的代价是：改一次样式要改四处，而且总有漏掉的——
//  分类色条、评分呈现、hairline 缩进这几轮改动就出现过四处不一致。
//
//  这里用「数据 + 可选配件」的形式收成一个组件：各页面的差异（下载进度条、
//  续读按钮、收藏夹备注）通过 meta 行与 accessory 插槽表达，
//  不必再各自复制一份布局。
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
    /// 标签 chip。列表接口本来就带 simpleTags，此前一直没用上——
    /// 卡片里那块空间给了分类名，而分类名现在已经在封面角标上。
    var tags: [String] = []
    var rating: Float? = nil             // nil = 不显示评分行
    var trailingText: String? = nil      // 发布时间，跟在评分条右侧
    var readProgress: Double? = nil      // 封面底部的阅读进度
    var progress: Double? = nil          // 独立的下载进度条
    var progressLabel: String? = nil
    var thumbnailSize: CGSize = EhSize.listThumbnail
    var titleLineLimit: Int = 2

    /// 行右侧的按钮（续读、暂停/重试…）
    var accessory: AnyView? = nil

    /// 标签 chip 上的文字：优先中文翻译，没有就去掉命名空间显示裸标签。
    /// 命名空间在 chip 里是噪音——`artist:onion knight kk` 占掉半行，
    /// 而用户扫的是「onion knight kk」这几个字。
    static func tagLabel(_ tag: String) -> String {
        if let zh = EhTagDatabase.shared.getTranslation(tag), zh != tag { return zh }
        guard let colon = tag.firstIndex(of: ":") else { return tag }
        return String(tag[tag.index(after: colon)...])
    }

    var body: some View {
        HStack(alignment: .top, spacing: EhSpacing.row) {
            EhCoverThumbnail(
                url: cover,
                size: thumbnailSize,
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
                    // 只铺一行，多的截断——列表行的价值是快速判断「要不要点进去」，
                    // 铺满标签会把标题挤成配角
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(4), id: \.self) { tag in
                            Text(Self.tagLabel(tag))
                                .font(.system(size: 10))
                                .foregroundStyle(EhColor.secondaryLabel)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(EhColor.fill)
                                }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 4)
                }

                if !meta.isEmpty {
                    HStack(spacing: EhSpacing.meta) {
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
            .frame(minHeight: thumbnailSize.height, alignment: .top)

            accessory
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

extension EhGalleryRow {
    /// 带配件的构造器
    init<A: View>(
        cover: String?,
        title: String,
        category: EhCategory? = nil,
        language: String? = nil,
        subtitle: String? = nil,
        meta: [MetaItem] = [],
        rating: Float? = nil,
        trailingText: String? = nil,
        readProgress: Double? = nil,
        progress: Double? = nil,
        progressLabel: String? = nil,
        thumbnailSize: CGSize = EhSize.listThumbnail,
        titleLineLimit: Int = 2,
        @ViewBuilder accessory: () -> A
    ) {
        self.init(
            cover: cover, title: title, category: category, language: language,
            subtitle: subtitle, meta: meta, rating: rating, trailingText: trailingText,
            readProgress: readProgress, progress: progress, progressLabel: progressLabel,
            thumbnailSize: thumbnailSize, titleLineLimit: titleLineLimit,
            accessory: AnyView(accessory())
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
