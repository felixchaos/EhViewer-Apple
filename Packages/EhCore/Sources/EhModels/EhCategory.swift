import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - 画廊分类 (位掩码，与 E-Hentai 服务端一致)

public struct EhCategory: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let misc       = EhCategory(rawValue: 0x1)
    public static let doujinshi  = EhCategory(rawValue: 0x2)
    public static let manga      = EhCategory(rawValue: 0x4)
    public static let artistCG   = EhCategory(rawValue: 0x8)
    public static let gameCG     = EhCategory(rawValue: 0x10)
    public static let imageSet   = EhCategory(rawValue: 0x20)
    public static let cosplay    = EhCategory(rawValue: 0x40)
    public static let asianPorn  = EhCategory(rawValue: 0x80)
    public static let nonH       = EhCategory(rawValue: 0x100)
    public static let western    = EhCategory(rawValue: 0x200)

    public static let all        = EhCategory(rawValue: 0x3FF)

    public var displayName: String {
        switch rawValue {
        case 0x1:   return "Misc"
        case 0x2:   return "Doujinshi"
        case 0x4:   return "Manga"
        case 0x8:   return "Artist CG"
        case 0x10:  return "Game CG"
        case 0x20:  return "Image Set"
        case 0x40:  return "Cosplay"
        case 0x80:  return "Asian Porn"
        case 0x100: return "Non-H"
        case 0x200: return "Western"
        default:    return "Unknown"
        }
    }

    /// 简短别名
    public var name: String { displayName }

    #if canImport(SwiftUI)
    /// 分类对应的颜色。
    ///
    /// 取值与 Android 端 `EhUtils.BG_COLOR_*` 逐项一致，不用 SwiftUI 的语义色
    /// （.red/.orange/…）——那些会随系统明暗切换成不同色值，而分类色是识别标识，
    /// 两端、两种外观下都必须是同一个颜色。
    public var color: Color {
        switch rawValue {
        case 0x2:   return Color(hex: 0xF44336)  // Doujinshi
        case 0x4:   return Color(hex: 0xFF9800)  // Manga
        case 0x8:   return Color(hex: 0xFBC02D)  // Artist CG
        case 0x10:  return Color(hex: 0x4CAF50)  // Game CG
        case 0x20:  return Color(hex: 0x3F51B5)  // Image Set
        case 0x40:  return Color(hex: 0x9C27B0)  // Cosplay
        case 0x80:  return Color(hex: 0x9575CD)  // Asian Porn
        case 0x100: return Color(hex: 0x2196F3)  // Non-H
        case 0x200: return Color(hex: 0x8BC34A)  // Western
        default:    return Color(hex: 0xF06292)  // Misc / Unknown
        }
    }

    /// 用于**文字**的分类色。
    ///
    /// 上面那组 Material 色是给白字填充块设计的，直接当小字用有两处读不清：
    /// 深色底上 Image Set 的靛蓝 (#3F51B5) 太暗，浅色底上 Artist CG 的黄
    /// (#FBC02D) 太浅。这里按外观把亮度推向可读区间，色相保持不变。
    public var labelColor: Color {
        color.ehContrastAdjusted()
    }
    #endif

    /// 从服务端字符串解析分类
    public static func from(string: String) -> EhCategory {
        switch string.lowercased() {
        case "misc":        return .misc
        case "doujinshi":   return .doujinshi
        case "manga":       return .manga
        case "artist cg":   return .artistCG
        case "game cg":     return .gameCG
        case "image set":   return .imageSet
        case "cosplay":     return .cosplay
        case "asian porn":  return .asianPorn
        case "non-h":       return .nonH
        case "western":     return .western
        default:            return .misc
        }
    }
}
