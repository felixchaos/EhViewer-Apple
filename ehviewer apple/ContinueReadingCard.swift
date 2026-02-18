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
            HStack(spacing: 12) {
                // 封面
                CachedAsyncImage(url: URL(string: record.thumb ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
                .frame(width: 48, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text("继续阅读")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)

                    Text(record.titleJpn ?? record.title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    if let progress = readingProgress, record.pages > 0 {
                        HStack(spacing: 6) {
                            // 进度条
                            ProgressView(value: Double(progress + 1), total: Double(record.pages))
                                .tint(.blue)
                                .frame(maxWidth: 100)
                            Text("\(progress + 1)/\(record.pages)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

#Preview {
    ContinueReadingCard()
}
