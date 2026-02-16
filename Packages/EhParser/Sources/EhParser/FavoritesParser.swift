import Foundation
import SwiftSoup
import EhModels

// MARK: - FavoritesParser (对应 Android FavoritesParser.java)
// 解析收藏页面，提取 10 个分类名称 + 计数，然后委托 GalleryListParser 解析画廊列表

public enum FavoritesParser {

    /// 收藏解析结果
    public struct FavResult: Sendable {
        /// 10 个收藏分类名称
        public var catArray: [String]
        /// 10 个收藏分类计数
        public var countArray: [Int]
        /// 当前选中分类 (0-9, -1=全部)
        public var currentCat: Int
        /// 画廊列表结果
        public var galleryListResult: GalleryListResult

        public init(
            catArray: [String] = Array(repeating: "", count: 10),
            countArray: [Int] = Array(repeating: 0, count: 10),
            currentCat: Int = -1,
            galleryListResult: GalleryListResult = GalleryListResult()
        ) {
            self.catArray = catArray
            self.countArray = countArray
            self.currentCat = currentCat
            self.galleryListResult = galleryListResult
        }
    }

    /// 收藏计数正则: (123)
    private static let countPattern = try! NSRegularExpression(
        pattern: #"\((\d+)\)"#
    )

    /// 解析收藏页面
    public static func parse(_ html: String) throws -> FavResult {
        let doc = try SwiftSoup.parse(html)
        var result = FavResult()

        // 解析收藏分类选择器 (.fp 元素)
        // Android: doc.select(".fp") → 11 个元素 (0=所有, 1-10=分组)
        let fps = try doc.select(".fp")
        var catIndex = 0

        for (idx, fp) in fps.array().enumerated() {
            // 第 0 个是 "Favorites" (所有收藏)，跳过
            if idx == 0 { continue }
            guard catIndex < 10 else { break }

            // 提取分类名 (对应 Android: child(2).text())
            let children = fp.children().array()
            if children.count >= 3 {
                result.catArray[catIndex] = (try? children[2].text()) ?? "Favorites \(catIndex)"
            } else {
                // 回退: 使用整个元素文本
                let text = (try? fp.text()) ?? ""
                // 移除末尾的 "(123)" 部分
                result.catArray[catIndex] = text
                    .replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }

            // 提取计数: 最后一个子元素或文本中的 (N)
            let fpText = (try? fp.text()) ?? ""
            let range = NSRange(fpText.startIndex..., in: fpText)
            if let match = countPattern.firstMatch(in: fpText, range: range),
               let countRange = Range(match.range(at: 1), in: fpText) {
                result.countArray[catIndex] = Int(fpText[countRange]) ?? 0
            }

            catIndex += 1
        }

        // 检测当前选中的分类
        // Android: 检查 .fp.fps 类 → selected (fps = "favorite panel selected")
        if let selected = try doc.select(".fp.fps").first() {
            let selectedText = try selected.text()
            // 判断是否为 "All Favorites": 文本含 "Favorites" 且在第一个位置
            let selectedOuterHtml = try selected.outerHtml()
            let firstFpHtml = fps.array().first.flatMap({ try? $0.outerHtml() })
            if selectedText.lowercased().contains("favorites") && !selectedText.contains("0") && selectedOuterHtml == firstFpHtml {
                result.currentCat = -1  // "All Favorites"
            } else {
                // 查找它在 fp 列表中的索引 (排除第一个)
                for (idx, fp) in fps.array().enumerated() {
                    let fpHtml = try fp.outerHtml()
                    if fpHtml == selectedOuterHtml {
                        result.currentCat = idx > 0 ? idx - 1 : -1
                        break
                    }
                }
            }
        }

        // 委托 GalleryListParser 解析画廊列表
        result.galleryListResult = try GalleryListParser.parse(html)

        return result
    }
}
