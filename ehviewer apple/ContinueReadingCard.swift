//
//  ContinueReadingCard.swift
//  ehviewer apple
//
//  Fix F2-1: "继续阅读" 快捷卡片
//  显示在首页列表顶部，一键恢复上次阅读位置 (类似 Apple Books)
//

import SwiftUI
import EhModels
import EhDatabase
import EhSettings

/// Loaded by the mounted Home view, not by the optional row itself. A List
/// has no row to mount while the record is absent, so a row task cannot bootstrap it.
struct ContinueReadingSnapshot: Sendable {
    let record: HistoryRecord
    let progress: Int?

    static func load() async -> Self? {
        await Task.detached(priority: .userInitiated) {
            let defaults = UserDefaults.standard
            let age = Date().timeIntervalSince1970 - defaults.double(forKey: "eh_last_reading_time")
            guard (0..<86400).contains(age),
                  let gid = (defaults.object(forKey: "eh_last_reading_gid") as? NSNumber)?.int64Value,
                  let record = try? EhDatabase.shared.getHistory(gid: gid) else { return nil }
            let progress = defaults.object(forKey: "reading_progress_\(gid)") as? Int
            return Self(record: record, progress: progress)
        }.value
    }
}

/// 继续阅读卡片 — 显示最近阅读的画廊，一键跳转阅读器
struct ContinueReadingCard: View {
    let snapshot: ContinueReadingSnapshot
    @State private var readerLaunchItem: ReaderLaunchItem?

    var body: some View {
        cardContent(record: snapshot.record)
        #if os(iOS)
        .fullScreenCover(item: $readerLaunchItem) { item in
            ImageReaderView(
                gid: item.gid,
                token: item.token,
                pages: item.pages,
                initialPage: item.initialPage
            )
            .presentationBackground(.clear)
        }
        #endif
    }

    @ViewBuilder
    private func cardContent(record: HistoryRecord) -> some View {
        Button {
            readerLaunchItem = ReaderLaunchItem(
                gid: record.gid,
                token: record.token,
                pages: record.pages,
                previewSet: nil,
                initialPage: nil
            )
        } label: {
            HStack(spacing: EhSpacing.row) {
                EhCoverThumbnail(
                    url: record.thumb,
                    size: EhSize.resumeThumbnail,
                    cornerRadius: EhRadius.smallThumbnail
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("继续阅读").ehSectionHeader()
                        .foregroundStyle(EhColor.accent)

                    Text(record.titleJpn ?? record.title)
                        .font(EhFont.body)
                        .lineLimit(1)
                        .foregroundStyle(EhColor.label)

                    if let progress = snapshot.progress, record.pages > 0 {
                        let page = progress + 1
                        let percent = Int(Double(page) / Double(record.pages) * 100)
                        Text("\(page) / \(record.pages) 页 · \(percent)%")
                            .font(EhFont.mono(11))
                            .foregroundStyle(EhColor.secondaryLabel)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(EhColor.onAccentFill)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(EhColor.accentFill))
            }
            .padding(.horizontal, EhSpacing.page)
            .padding(.vertical, 10)
            // 左浓右淡的琥珀渐隐：把这一条与下方的普通列表行区分开，
            // 又不至于像一整块实心卡片那样从列表里割裂出去
            .background(
                LinearGradient(
                    colors: [EhColor.accentWash, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-continue-reading")
        .padding(.top, 8)
    }
}

#Preview {
    ContinueReadingCard(snapshot: .init(
        record: .init(gid: 1, token: "preview", title: "Preview gallery", pages: 3, date: Date()),
        progress: 1
    ))
}
