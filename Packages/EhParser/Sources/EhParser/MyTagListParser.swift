import Foundation
import EhModels
import SwiftSoup

// MARK: - 用户标签列表解析器 (对应 Android MyTagLitParser.java)

public enum MyTagListParser {

    /// 错误检测正则
    private static let errorRegex = try! NSRegularExpression(
        pattern: #"<div class="d">\n<p>([^<]+)</p>"#
    )

    /// 解析用户标签列表 (对应 Android MyTagLitParser.parse)
    public static func parse(_ body: String) throws -> UserTagList {
        var list = UserTagList()

        // 错误检测
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        if let match = errorRegex.firstMatch(in: body, range: fullRange),
           let range = Range(match.range(at: 1), in: body) {
            throw MyTagError.serverError(String(body[range]))
        }

        let doc = try SwiftSoup.parse(body)
        guard let outer = try doc.getElementById("usertags_outer") else {
            return list
        }

        // Skip the header when present. An empty container is a valid empty list.
        for tag in outer.children().dropFirst() {
            if let userTag = parseUserTag(tag) {
                list.userTags.append(userTag)
            }
        }

        return list
    }

    /// 解析单个用户标签 (对应 Android MyTagLitParser.parserUserTag)
    private static func parseUserTag(_ tag: Element) -> UserTag? {
        do {
            let userTagId = tag.id()
            let id = String(userTagId.dropFirst("usertag_".count))

            // tagName: #tagpreview{id} 的 title 属性
            let nameId = "tagpreview\(id)"
            let tagName = try tag.getElementById(nameId)?.attr("title") ?? ""

            // watched: #tagwatch{id} 的 checked 属性
            let watchId = "tagwatch\(id)"
            let watchInput = try tag.getElementById(watchId)
            let watched = (try watchInput?.attr("checked")) == "checked"

            // hidden: #taghide{id} 的 checked 属性
            let hideId = "taghide\(id)"
            let hideInput = try tag.getElementById(hideId)
            let hidden = (try hideInput?.attr("checked")) == "checked"

            // color: #tagcolor{id} 的 placeholder 属性
            let colorId = "tagcolor\(id)"
            let color = try tag.getElementById(colorId)?.attr("placeholder")

            // tagWeight: #tagweight{id} 的 value 属性
            let weightId = "tagweight\(id)"
            let weightString = try tag.getElementById(weightId)?.attr("value") ?? "0"
            let tagWeight = Int(weightString) ?? 0

            return UserTag(
                userTagId: userTagId,
                tagName: tagName,
                watched: watched,
                hidden: hidden,
                color: color?.isEmpty == true ? nil : color,
                tagWeight: tagWeight
            )
        } catch {
            return nil
        }
    }
}

// MARK: - 错误

public enum MyTagError: LocalizedError, Sendable {
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .serverError(let msg): return msg
        }
    }
}
