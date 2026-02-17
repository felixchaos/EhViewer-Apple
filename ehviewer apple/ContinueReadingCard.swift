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
    @State private var showReader = false

    var body: some View {
        Group {
            if let record = latestRecord, shouldShow {
                cardContent(record: record)
            }
        }
        .onAppear { loadLatestReading() }
        #if os(iOS)
        .fullScreenCover(isPresented: $showReader) {
            if let record = latestRecord {
                ImageReaderView(
                    gid: record.gid,
                    token: record.token,
                    pages: record.pages,
                    initialPage: readingProgress
                )
                .id(record.gid)
            }
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

    private func loadLatestReading() {
        let lastGid = UserDefaults.standard.object(forKey: "eh_last_reading_gid") as? Int64
        guard let gid = lastGid else { return }

        // 从历史数据库查找
        do {
            let allHistory = try EhDatabase.shared.getAllHistory(limit: 1)
            if let first = allHistory.first, first.gid == gid {
                latestRecord = first
            } else {
                // history 表中最新的不是最后阅读的 → 按 gid 查找
                let searched = try EhDatabase.shared.getAllHistory(limit: 50)
                latestRecord = searched.first(where: { $0.gid == gid })
            }
        } catch {
            debugLog("[ContinueReadingCard] Failed to load history: \(error)")
        }

        // 读取阅读进度
        let key = "reading_progress_\(gid)"
        if let saved = UserDefaults.standard.object(forKey: key) as? Int {
            readingProgress = saved
        }
    }

    @ViewBuilder
    private func cardContent(record: HistoryRecord) -> some View {
        Button {
            showReader = true
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
