//
//  ResponsiveLayout.swift
//  ehviewer apple
//
//  响应式布局工具 - 支持多平台动态尺寸计算
//

import SwiftUI

/// 响应式布局配置
struct ResponsiveLayout {
    let horizontalSizeClass: UserInterfaceSizeClass?
    let width: CGFloat
    let height: CGFloat

    init(size: CGSize, horizontalSizeClass: UserInterfaceSizeClass? = nil) {
        self.width = size.width
        self.height = size.height
        self.horizontalSizeClass = horizontalSizeClass
    }

    // MARK: - 设备类型判断

    var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return width < 600
        #endif
    }

    var isRegular: Bool {
        !isCompact
    }

    var isLargeScreen: Bool {
        width >= 768
    }

    var isExtraLargeScreen: Bool {
        width >= 1024
    }

    // MARK: - 画廊列表缩略图尺寸

    var galleryThumbnailSize: CGSize {
        let baseWidth: CGFloat = 76
        let baseHeight: CGFloat = 106
        let aspectRatio = baseHeight / baseWidth

        let scaledWidth: CGFloat
        if isExtraLargeScreen {
            scaledWidth = baseWidth * 1.3  // macOS/iPad Pro: 98.8
        } else if isLargeScreen {
            scaledWidth = baseWidth * 1.15 // iPad: 87.4
        } else {
            scaledWidth = baseWidth        // iPhone: 76
        }

        return CGSize(width: scaledWidth, height: scaledWidth * aspectRatio)
    }

    // MARK: - 画廊详情封面尺寸

    var galleryDetailCoverSize: CGSize {
        let baseWidth: CGFloat = 120
        let baseHeight: CGFloat = 168
        let aspectRatio = baseHeight / baseWidth

        let scaledWidth: CGFloat
        if isExtraLargeScreen {
            scaledWidth = baseWidth * 1.5  // macOS/iPad Pro: 180
        } else if isLargeScreen {
            scaledWidth = baseWidth * 1.25 // iPad: 150
        } else {
            scaledWidth = baseWidth        // iPhone: 120
        }

        return CGSize(width: scaledWidth, height: scaledWidth * aspectRatio)
    }

    // MARK: - 画廊详情预览图尺寸

    var galleryPreviewSize: CGSize {
        let baseWidth: CGFloat = 100
        let baseHeight: CGFloat = 142
        let aspectRatio = baseHeight / baseWidth

        let scaledWidth: CGFloat
        if isExtraLargeScreen {
            scaledWidth = baseWidth * 1.4  // macOS/iPad Pro: 140
        } else if isLargeScreen {
            scaledWidth = baseWidth * 1.2  // iPad: 120
        } else {
            scaledWidth = baseWidth        // iPhone: 100
        }

        return CGSize(width: scaledWidth, height: scaledWidth * aspectRatio)
    }

    var galleryPreviewGridColumns: Int {
        if isExtraLargeScreen {
            return Int(width / 160) // macOS: ~6-12列
        } else if isLargeScreen {
            return Int(width / 140) // iPad: ~5-7列
        } else {
            return Int(width / 110) // iPhone: ~3-4列
        }
    }

    // MARK: - 图片阅读器缩略图尺寸

    var readerThumbnailSize: CGSize {
        let baseWidth: CGFloat = 60
        let baseHeight: CGFloat = 84
        let aspectRatio = baseHeight / baseWidth

        let scaledWidth: CGFloat
        if isExtraLargeScreen {
            scaledWidth = baseWidth * 1.3  // macOS/iPad Pro: 78
        } else if isLargeScreen {
            scaledWidth = baseWidth * 1.15 // iPad: 69
        } else {
            scaledWidth = baseWidth        // iPhone: 60
        }

        return CGSize(width: scaledWidth, height: scaledWidth * aspectRatio)
    }

    var readerThumbnailBarHeight: CGFloat {
        if isExtraLargeScreen {
            return 120  // macOS/iPad Pro
        } else if isLargeScreen {
            return 110  // iPad
        } else {
            return 100  // iPhone
        }
    }

    // MARK: - NavigationSplitView 侧边栏宽度

    var splitViewSidebarWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        if isExtraLargeScreen {
            return (min: 400, ideal: 480, max: 600)  // macOS/iPad Pro
        } else if isLargeScreen {
            return (min: 350, ideal: 400, max: 500)  // iPad
        } else {
            return (min: 280, ideal: 320, max: 400)  // iPhone (不太可能用到)
        }
    }

    // MARK: - 右侧抽屉宽度 (画廊列表筛选)

    var drawerWidth: CGFloat {
        if isExtraLargeScreen {
            return min(320, width * 0.25)  // macOS: 最多占 25%
        } else if isLargeScreen {
            return 300                      // iPad
        } else {
            return 280                      // iPhone
        }
    }

    // MARK: - 动态 Padding

    var horizontalPadding: CGFloat {
        if isExtraLargeScreen {
            return 24
        } else if isLargeScreen {
            return 20
        } else {
            return 16
        }
    }

    var verticalPadding: CGFloat {
        if isExtraLargeScreen {
            return 20
        } else if isLargeScreen {
            return 16
        } else {
            return 12
        }
    }

    var sectionSpacing: CGFloat {
        if isExtraLargeScreen {
            return 32
        } else if isLargeScreen {
            return 24
        } else {
            return 16
        }
    }

    // MARK: - 搜索建议浮层偏移

    var searchSuggestionsTopOffset: CGFloat {
        #if os(iOS)
        return 44  // iOS 搜索栏高度相对固定
        #else
        return 52  // macOS 搜索栏可能更高
        #endif
    }
}

// MARK: - SwiftUI Environment Key

struct ResponsiveLayoutKey: EnvironmentKey {
    static var defaultValue: ResponsiveLayout {
        ResponsiveLayout(size: CGSize(width: 375, height: 667))
    }
}

extension EnvironmentValues {
    var responsiveLayout: ResponsiveLayout {
        get { self[ResponsiveLayoutKey.self] }
        set { self[ResponsiveLayoutKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    /// 注入响应式布局环境
    func withResponsiveLayout(size: CGSize, horizontalSizeClass: UserInterfaceSizeClass? = nil) -> some View {
        let layout = ResponsiveLayout(size: size, horizontalSizeClass: horizontalSizeClass)
        return self.environment(\.responsiveLayout, layout)
    }
}

// MARK: - GeometryReader Wrapper

struct ResponsiveContainer<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let content: (ResponsiveLayout) -> Content

    var body: some View {
        GeometryReader { geometry in
            let layout = ResponsiveLayout(
                size: geometry.size,
                horizontalSizeClass: horizontalSizeClass
            )
            content(layout)
                .environment(\.responsiveLayout, layout)
        }
    }
}
