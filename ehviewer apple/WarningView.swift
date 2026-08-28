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
            Text("内容警告")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(EhColor.label)
                .padding(.bottom, 16)
            
            // 警告内容
            VStack(alignment: .leading, spacing: 12) {
                warningText("本应用可能包含成人内容（18+），包括但不限于：")
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 8) {
                    bulletPoint("成人向绘画和插图")
                    bulletPoint("裸露或性暗示内容")
                    bulletPoint("其他可能不适合未成年人的内容")
                }
                .padding(.leading, 8)
                
                warningText("继续使用本应用即表示您确认：")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    bulletPoint("您已年满 18 周岁")
                    bulletPoint("您所在地区法律允许访问此类内容")
                    bulletPoint("您自愿并知情地访问这些内容")
                }
                .padding(.leading, 8)
            }
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
