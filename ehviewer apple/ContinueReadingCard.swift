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

/// 继续阅读卡片 — 显示最近阅读的画廊，一键跳转阅读器
struct ContinueReadingCard: View {
    @State private var latestRecord: HistoryRecord?
    @State private var readingProgress: Int?
    @State private var readerLaunchItem: ReaderLaunchItem?

    var body: some View {
        Group {
            if let record = latestRecord, shouldShow {
                cardContent(record: record)
            }
        }
        // ⚠️ 关键修复: 使用 .task (异步) 替代 .onAppear (同步)
        // 原 .onAppear 在主线程同步调用 dbQueue.read → 如果后台 VACUUM 持有 dbQueue，
        // 主线程永久阻塞 → .task 永远无法执行 → 白屏 + 发热 + 闪退
        .task { await loadLatestReadingAsync() }
        #if os(iOS)
        .fullScreenCover(item: $readerLaunchItem) { item in
            ImageReaderView(
                gid: item.gid,
                token: item.token,
                pages: item.pages,
                initialPage: item.initialPage
            )
        }
        #endif
    }

    /// 只在最近 24 小时内有阅读记录时显示
    private var shouldShow: Bool {
        guard let timestamp = UserDefaults.standard.object(forKey: "eh_last_reading_time") as? TimeInterval else {
            return false
        }
        let lastTime = Date(timeIntervalSince1970: timestamp)
        return Date().timeIntervalSince(lastTime) < 86400 // 24 小时
    }

    /// 异步加载最近阅读记录 — 数据库操作在后台线程执行，不阻塞主线程
    private func loadLatestReadingAsync() async {
        let lastGid = UserDefaults.standard.object(forKey: "eh_last_reading_gid") as? Int64
        guard let gid = lastGid else { return }

        // 在后台线程执行数据库读取，避免 DatabaseQueue 串行锁阻塞主线程
        let result: (record: HistoryRecord?, progress: Int?) = await Task.detached {
            var record: HistoryRecord?
            do {
                let allHistory = try EhDatabase.shared.getAllHistory(limit: 1)
                if let first = allHistory.first, first.gid == gid {
                    record = first
                } else {
                    let searched = try EhDatabase.shared.getAllHistory(limit: 50)
                    record = searched.first(where: { $0.gid == gid })
                }
            } catch {
                print("[ContinueReadingCard] Failed to load history: \(error)")
            }

            let key = "reading_progress_\(gid)"
            let progress = UserDefaults.standard.object(forKey: key) as? Int
            return (record, progress)
        }.value

        // 回到主线程更新 @State
        latestRecord = result.record
        readingProgress = result.progress
    }

    @ViewBuilder
    private func cardContent(record: HistoryRecord) -> some View {
        Button {
            readerLaunchItem = ReaderLaunchItem(
                gid: record.gid,
                token: record.token,
                pages: record.pages,
                previewSet: nil,
                initialPage: readingProgress
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

                    if let progress = readingProgress, record.pages > 0 {
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
        .padding(.top, 8)
    }
}

#Preview {
    ContinueReadingCard()
}
