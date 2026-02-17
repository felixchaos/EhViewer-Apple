//
//  SelectSiteView.swift
//  ehviewer apple
//
//  站点选择引导页 (对应 Android SelectSiteScene)
//  首次启动时让用户选择默认使用的站点
//

import SwiftUI
import EhSettings

/// 站点选择视图
/// 首次使用时展示，让用户选择 E-Hentai 或 ExHentai
struct SelectSiteView: View {
    let onComplete: () -> Void
    
    @State private var selectedSite: EhSite = .eHentai
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // 标题
            Text("欢迎使用 EhViewer")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 8)
            
            Text("请选择默认访问的站点")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)
            
            // 站点选项
            VStack(spacing: 16) {
                siteOption(
                    site: .eHentai,
                    title: "E-Hentai",
                    description: "标准版本，无需登录即可访问大部分内容",
                    icon: "globe"
                )
                
                siteOption(
                    site: .exHentai,
                    title: "ExHentai",
                    description: "完整版本，需要账号登录，包含更多内容",
                    icon: "globe.badge.chevron.backward"
                )
            }
            .padding(.horizontal, 24)
            
            // 提示
            VStack(spacing: 8) {
                Text("您可以稍后在设置中更改此选项")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                
                if selectedSite == .exHentai {
                    VStack(spacing: 4) {
                        Text("⚠️ ExHentai 需要特定账号权限才能访问")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Text("如果您的账号不支持，登录后将自动切换到 E-Hentai")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 24)
            
            Spacer()
            
            // 确认按钮
            Button(action: confirmSelection) {
                Text("开始使用")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func siteOption(site: EhSite, title: String, description: String, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSite = site
            }
        } label: {
            HStack(spacing: 16) {
                // 图标
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(selectedSite == site ? .white : .blue)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedSite == site ? Color.blue : Color.blue.opacity(0.1))
                    )
                
                // 文字
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // 选中标记
                Image(systemName: selectedSite == site ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selectedSite == site ? .blue : .secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selectedSite == site ? Color.blue : Color.secondary.opacity(0.3), lineWidth: 2)
            )
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(selectedSite == site ? Color.blue.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func confirmSelection() {
        // 保存选择
        AppSettings.shared.gallerySite = selectedSite
        AppSettings.shared.hasSelectedSite = true
        
        // 完成引导
        onComplete()
    }
}

#Preview {
    SelectSiteView(onComplete: { print("Complete") })
}
