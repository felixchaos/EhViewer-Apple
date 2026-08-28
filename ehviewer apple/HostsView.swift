//
//  HostsView.swift
//  ehviewer apple
//
//  自定义 Hosts — 对齐 Android HostsActivity
//
//  `EhDNS` 一直有 setUserHost / removeUserHost，但没有界面，也不持久化（重启就没了）。
//  内置 IP 表会过期，被墙或 DNS 污染时用户需要能自己填一条能通的 IP。
//

import SwiftUI
import EhDNS

struct HostsView: View {
    @State private var entries: [HostEntry] = []
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var newIPs = ""

    /// IP → 最近一次探测结果
    @State private var latencies: [String: HostLatency] = [:]
    @State private var isProbing = false

    @ViewBuilder
    private func latencyBadge(for ip: String?) -> some View {
        if let ip, let latency = latencies[ip] {
            HStack(spacing: 5) {
                Circle()
                    .fill(color(for: latency.grade))
                    .frame(width: 7, height: 7)
                Text(latency.milliseconds.map { "\($0) ms" } ?? "不可达")
                    .font(EhFont.mono(11))
                    .foregroundStyle(EhColor.secondaryLabel)
            }
        } else if isProbing {
            ProgressView().controlSize(.mini)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func color(for grade: HostLatency.Grade) -> Color {
        switch grade {
        case .good:        return EhColor.success
        case .fair:        return EhColor.warning
        case .poor:        return EhColor.warning
        case .unreachable: return EhColor.danger
        }
    }

    private func probeAll() async {
        let ips = entries.compactMap { $0.ips.first }
        guard !ips.isEmpty else { return }
        isProbing = true
        latencies = await HostLatencyProbe.shared.measureAll(ips: ips)
        isProbing = false
    }

    var body: some View {
        Form {
            Section {
                if entries.isEmpty {
                    Text("还没有自定义记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack(spacing: EhSpacing.row) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.host)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(EhColor.label)
                                Text(entry.ips.joined(separator: ", "))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(EhColor.secondaryLabel)
                            }
                            Spacer(minLength: 8)
                            // 一条早已失效的记录和一条正常记录此前长得一模一样，
                            // 用户只能靠「打不开」反推。这里把可达性直接标出来。
                            latencyBadge(for: entry.ips.first)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            EhDNS.shared.removeUserHost(entries[index].host)
                        }
                        reload()
                    }
                }
            } header: {
                Text("自定义记录")
            } footer: {
                Text("自定义记录优先于内置 IP 表。左滑删除。")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("添加记录", systemImage: "plus")
                }

                if !entries.isEmpty {
                    Button(role: .destructive) {
                        EhDNS.shared.clearUserHosts()
                        reload()
                    } label: {
                        Text("清空全部")
                    }
                }
            }
        }
        .navigationTitle("自定义 Hosts")
        .task { await probeAll() }
        .refreshable { await probeAll() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { reload() }
        .alert("添加记录", isPresented: $showAdd) {
            TextField("域名，如 exhentai.org", text: $newHost)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("IP，多个用逗号分隔", text: $newIPs)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("添加") { add() }
            Button("取消", role: .cancel) { clearDraft() }
        } message: {
            Text("填一条你确认能连通的 IP。填错会让该域名彻底连不上，删掉即可恢复。")
        }
    }

    private func add() {
        let host = newHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ips = newIPs
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        defer { clearDraft() }
        guard !host.isEmpty, !ips.isEmpty else { return }
        EhDNS.shared.setUserHost(host, ips: ips)
        reload()
    }

    private func clearDraft() {
        newHost = ""
        newIPs = ""
    }

    private func reload() {
        entries = EhDNS.shared.allUserHosts()
            .map { HostEntry(host: $0.key, ips: $0.value) }
            .sorted { $0.host < $1.host }
    }
}

struct HostEntry: Identifiable, Hashable {
    let host: String
    let ips: [String]
    var id: String { host }
}
