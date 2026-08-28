//
//  EhPageHeader.swift
//  ehviewer apple
//
//  紧凑页头 — 标题与动作同一行
//
//  此前用系统的 `.navigationBarTitleDisplayMode(.large)`：它会先留一条空的
//  导航栏带（约 44pt），再在下面放大标题（约 52pt），动作按钮浮在那条空带里。
//  于是标题左边、按钮下面各有一大块什么都没有的区域——下载、历史、我的
//  三屏顶部的空白就是这么来的，加起来白白吃掉近百点垂直空间。
//
//  设计稿是「标题 + 动作」并排一行，直接压在状态栏下方。这里就照这个做，
//  并把系统导航栏隐藏掉，避免两套标题叠在一起。
//

import SwiftUI

struct EhPageHeader<Trailing: View>: View {
    let title: String
    /// 标题下方的一行小字（如「云端同步 · 2 分钟前」）
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: EhSpacing.row) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(EhColor.label)
                if let subtitle {
                    Text(subtitle)
                        .font(EhFont.footnote)
                        .foregroundStyle(EhColor.tertiaryLabel)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 18) {
                trailing()
            }
            .font(.system(size: 17))
            .foregroundStyle(EhColor.accent)
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

extension EhPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// 用紧凑页头替代系统大标题。
    ///
    /// 必须同时隐藏系统导航栏，否则会出现「空的导航栏带 + 自绘标题」两层。
    func ehCompactHeader() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
