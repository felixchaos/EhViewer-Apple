//
//  DownloadLabelPicker.swift
//  ehviewer apple
//
//  下载标签选择器 — 对齐 Android CommonOperations.startDownload
//
//  Android 在发起下载前会弹一个标签列表（默认分组 + 用户建的标签），
//  底下带一个「记住下载标签」的勾选框。iOS 端此前完全没有这一步：
//  下载页里能建标签、能改名，但新下载永远进默认分组，标签建了没用。
//

import SwiftUI
import EhSettings
import EhDatabase

struct DownloadLabelPicker: View {
    /// nil = 默认分组（对齐 Android 的 label == null）
    let onSelect: (String?) -> Void
    let onCancel: () -> Void

    @State private var labels: [DownloadLabelRecord] = []
    /// 对齐 Android remember_download_label：勾了就把选择存成默认，
    /// 之后直接下不再问；不勾则把默认清掉。
    @State private var remember = false

    private func pick(_ label: String?) {
        AppSettings.shared.hasDefaultDownloadLabel = remember
        AppSettings.shared.defaultDownloadLabel = remember ? label : nil
        onSelect(label)
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    pick(nil)
                } label: {
                    HStack {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                        Text("默认分组").foregroundStyle(.primary)
                        Spacer()
                    }
                }

                ForEach(labels, id: \.label) { record in
                    Button {
                        pick(record.label)
                    } label: {
                        HStack {
                            Image(systemName: "tag")
                                .foregroundStyle(EhColor.accent)
                            Text(record.label).foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }

                Section {
                    Toggle("记住这个标签，下次不再询问", isOn: $remember)
                        .tint(EhColor.accentFill)
                } footer: {
                    Text("可以在「下载 › 更多 › 下载标签」里改回每次询问。")
                }
            }
            .navigationTitle("下载到")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
            .task {
                labels = (try? EhDatabase.shared.getAllDownloadLabels()) ?? []
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
