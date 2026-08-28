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
            Spacer(minLength: 40)

            // 品牌区与登录页保持一致：同一段引导流程里换一种视觉语言很突兀
            Image("AppLogo")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(EhColor.cardStroke, lineWidth: 0.5)
                }
                .padding(.bottom, 18)

            Text("欢迎使用 EhViewer")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(EhColor.label)
                .padding(.bottom, 6)

            Text("先选一个默认站点，之后可以随时切换")
                .font(EhFont.caption)
                .foregroundStyle(EhColor.secondaryLabel)
                .padding(.bottom, 32)

            VStack(spacing: 10) {
                siteOption(
                    site: .eHentai,
                    title: "E-Hentai",
                    description: "无需登录即可浏览大部分内容",
                    icon: "globe"
                )
                siteOption(
                    site: .exHentai,
                    title: "ExHentai",
                    description: "内容更全，需要账号且账号需具备访问权限",
                    icon: "globe.badge.chevron.backward"
                )
            }
            .padding(.horizontal, EhSpacing.page)

            if selectedSite == .exHentai {
                // 只在选了 ExHentai 时出现：这条提醒对选 E-Hentai 的人是噪音
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(EhColor.warning)
                    Text("账号若不具备 ExHentai 权限，登录后会自动退回 E-Hentai。")
                        .font(EhFont.footnote)
                        .foregroundStyle(EhColor.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, EhSpacing.page + 4)
                .padding(.top, 14)
            }

            Spacer(minLength: 24)

            Button("开始使用", action: confirmSelection)
                .buttonStyle(EhFilledButtonStyle(height: EhSize.actionButtonHeight))
                .padding(.horizontal, EhSpacing.page)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EhColor.background)
        .animation(.easeInOut(duration: 0.2), value: selectedSite)
    }

    @ViewBuilder
    private func siteOption(site: EhSite, title: String, description: String, icon: String) -> some View {
        let isSelected = selectedSite == site
        Button {
            selectedSite = site
            Haptics.tap()
        } label: {
            HStack(spacing: EhSpacing.row) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? EhColor.onAccentFill : EhColor.accent)
                    .frame(width: 44, height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: EhRadius.control, style: .continuous)
                            .fill(isSelected ? EhColor.accentFill : EhColor.fill)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(EhFont.title)
                        .foregroundStyle(EhColor.label)
                    Text(description)
                        .font(EhFont.meta)
                        .foregroundStyle(EhColor.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? EhColor.accent : EhColor.tertiaryLabel)
            }
            .padding(EhSpacing.page)
            .background {
                RoundedRectangle(cornerRadius: EhRadius.card, style: .continuous)
                    .fill(EhColor.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: EhRadius.card, style: .continuous)
                            .strokeBorder(
                                isSelected ? EhColor.accentFill : EhColor.cardStroke,
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    }
            }
            .contentShape(Rectangle())
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
