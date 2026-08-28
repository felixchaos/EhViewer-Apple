//
//  WarningView.swift
//  ehviewer apple
//
//  18+ 内容警告页面 (对应 Android WarningScene)
//

import SwiftUI

/// 18+ 内容警告视图
/// 首次启动时显示，用户必须接受才能继续使用
struct WarningView: View {
    let onAccept: () -> Void
    let onReject: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // 警告图标
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                // 用红而非黄：这是一道需要用户如实回答的门槛，
                // 黄色读起来像「注意一下」，红色才是「请确认」
                .foregroundStyle(EhColor.danger)
                .padding(.bottom, 20)

            // 标题
            Text("本应用包含成人内容")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(EhColor.label)
                .multilineTextAlignment(.center)
                .padding(.bottom, 14)

            // 设计稿这版比原先的项目符号列表短得多，而且补上了「不托管内容」
            // 这句免责——原文案通篇在描述内容形态，反而漏了这个更要紧的事实。
            Text("继续使用表示你已满足所在地区的法定年龄要求，并自行承担浏览责任。本应用不托管任何内容，仅作为 E-Hentai / ExHentai 的第三方客户端。")
                .font(EhFont.body)
                .foregroundStyle(EhColor.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)

            Spacer()
            
            // 按钮区域
            VStack(spacing: 12) {
                Button("我已满 18 岁，继续", action: onAccept)
                    .buttonStyle(EhFilledButtonStyle(height: EhSize.actionButtonHeight))

                Button("退出", action: onReject)
                    .buttonStyle(EhTintedButtonStyle(height: EhSize.actionButtonHeight))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EhColor.background)
    }

    private func warningText(_ text: String) -> some View {
        Text(text)
            .font(EhFont.body)
            .foregroundStyle(EhColor.label)
    }
    
    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

#Preview {
    WarningView(
        onAccept: { print("Accepted") },
        onReject: { print("Rejected") }
    )
}
