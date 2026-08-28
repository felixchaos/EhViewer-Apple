//
//  HostLatencyProbe.swift
//  ehviewer apple
//
//  自定义 Hosts 记录的可达性探测
//
//  自定义 Hosts 是用来绕开 DNS 污染的，但填进去的 IP 是否还活着，界面上此前
//  完全看不出来 —— 一条早已失效的记录和一条正常的记录长得一模一样，
//  用户只能靠「打不开」反推。
//
//  这里测的是到 IP:443 的 **TCP 连接建立耗时**，不是 ICMP ping：
//    - iOS 沙盒里发 ICMP 需要原始套接字，普通 App 拿不到权限
//    - 真正要用的就是 443，连得上才有意义；ICMP 通而 443 被封的情况并不少见
//

import Foundation
import Network

/// 一次探测的结果
struct HostLatency: Sendable {
    let milliseconds: Int?   // nil 表示连接失败或超时

    var isReachable: Bool { milliseconds != nil }

    /// 状态点颜色的分档依据。阈值取自日常体感：
    /// 200ms 以内基本无感，600ms 以上翻页会明显等待。
    enum Grade { case good, fair, poor, unreachable }

    var grade: Grade {
        guard let ms = milliseconds else { return .unreachable }
        if ms < 200 { return .good }
        if ms < 600 { return .fair }
        return .poor
    }
}

actor HostLatencyProbe {
    static let shared = HostLatencyProbe()

    private var cache: [String: HostLatency] = [:]
    private var inFlight: [String: Task<HostLatency, Never>] = [:]

    private init() {}

    func cached(for ip: String) -> HostLatency? { cache[ip] }

    /// 探测一个 IP。同一 IP 的并发请求合并成一次。
    func measure(ip: String, timeout: TimeInterval = 3) async -> HostLatency {
        if let running = inFlight[ip] { return await running.value }

        let task = Task<HostLatency, Never> {
            await Self.connectLatency(ip: ip, timeout: timeout)
        }
        inFlight[ip] = task
        let result = await task.value
        inFlight[ip] = nil
        cache[ip] = result
        return result
    }

    func measureAll(ips: [String]) async -> [String: HostLatency] {
        await withTaskGroup(of: (String, HostLatency).self) { group in
            for ip in ips {
                group.addTask { (ip, await self.measure(ip: ip)) }
            }
            var out: [String: HostLatency] = [:]
            for await (ip, latency) in group { out[ip] = latency }
            return out
        }
    }

    private static func connectLatency(ip: String, timeout: TimeInterval) async -> HostLatency {
        guard let host = IPv4Address(ip).map(NWEndpoint.Host.ipv4)
            ?? IPv6Address(ip).map(NWEndpoint.Host.ipv6) else {
            return HostLatency(milliseconds: nil)
        }

        let params = NWParameters.tcp
        // 不做 TLS 握手：只关心链路是否可达，握手会把耗时和证书协商混在一起
        let connection = NWConnection(host: host, port: 443, using: params)

        return await withCheckedContinuation { continuation in
            let start = DispatchTime.now()
            // Swift 6 下 continuation 只能恢复一次，用一个串行队列守住这个不变量
            let lock = NSLock()
            var finished = false
            func finish(_ result: HostLatency) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    finish(HostLatency(milliseconds: Int(ns / 1_000_000)))
                case .failed, .cancelled:
                    finish(HostLatency(milliseconds: nil))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(HostLatency(milliseconds: nil))
            }
        }
    }
}
