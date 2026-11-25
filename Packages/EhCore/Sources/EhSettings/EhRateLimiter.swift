//
//  EhRateLimiter.swift
//  EhCore
//
//  全局速率限制器 — 防止 IP 封禁 (V-08, V-09)
//  Token Bucket: API 请求 2 次/秒, burst 3
//  Semaphore: 图片下载全局最多 5 并发
//

import Foundation

/// 全局速率限制器 — 所有网络请求共享同一实例
/// - API 请求 (EhAPI): `await waitApiSlot()` → token bucket, 2 req/sec, burst 3
/// - 图片下载 (SpiderQueen): `try await acquireImageSlot()` / `releaseImageSlot()` → 全局最多 5 并发
public actor EhRateLimiter {
    public static let shared = EhRateLimiter()

    // MARK: - Token Bucket (API)

    /// 桶容量 (burst 上限)
    private let apiBurstCapacity: Double = 3.0
    /// 每秒填充速率 (tokens/sec)
    private let apiRefillRate: Double = 2.0
    /// 当前可用 token 数
    private var apiTokens: Double = 3.0
    /// 上次填充时间
    private var apiLastRefill: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // MARK: - Semaphore (Image Downloads)

    /// 全局最大并发图片下载数
    private let maxImageConcurrent = 5
    /// 当前活跃下载数
    private var activeImageCount = 0
    /// 等待队列 — FIFO
    private struct ImageWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var imageWaiters: [ImageWaiter] = []

    var queuedImageWaiterCount: Int { imageWaiters.count }

    // MARK: - API Slot

    /// 等待直到可用 API token — 每次调用消耗 1 token
    /// 如果桶空则休眠直到填充足够的 token (带随机抖动防止 thundering herd)
    public func waitApiSlot() async {
        refillApiTokens()

        if apiTokens >= 1.0 {
            apiTokens -= 1.0
            return
        }

        // 计算需要等待的时间
        let deficit = 1.0 - apiTokens
        let waitSeconds = deficit / apiRefillRate
        // 添加 ±20% 随机抖动
        let jitter = waitSeconds * Double.random(in: -0.2...0.2)
        let totalWait = max(0.05, waitSeconds + jitter)

        try? await Task.sleep(nanoseconds: UInt64(totalWait * 1_000_000_000))

        // 休眠后重新填充并消耗
        refillApiTokens()
        apiTokens = max(0, apiTokens - 1.0)
    }

    /// 根据经过的时间填充 token
    private func refillApiTokens() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - apiLastRefill
        apiLastRefill = now
        apiTokens = min(apiBurstCapacity, apiTokens + elapsed * apiRefillRate)
    }

    // MARK: - Image Slot

    /// 获取一个图片下载槽位 — 如果当前并发已满则挂起等待
    public func acquireImageSlot() async throws {
        try Task.checkCancellation()
        if activeImageCount < maxImageConcurrent {
            activeImageCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    imageWaiters.append(.init(id: id, continuation: cont))
                }
            }
        } onCancel: {
            Task { await self.cancelImageWaiter(id) }
        }
    }

    private func cancelImageWaiter(_ id: UUID) {
        guard let index = imageWaiters.firstIndex(where: { $0.id == id }) else { return }
        imageWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// 释放一个图片下载槽位 — 唤醒等待队列中的下一个
    public func releaseImageSlot() {
        if !imageWaiters.isEmpty {
            // 有等待者 → 不减 activeImageCount (槽位直接移交)
            let next = imageWaiters.removeFirst()
            // 注意: 不需要 activeImageCount 变化 — 槽位从释放者直接转移给等待者
            next.continuation.resume()
        } else {
            activeImageCount -= 1
        }
    }
}
