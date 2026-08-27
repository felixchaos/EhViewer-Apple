import Foundation
import SwiftSoup
import EhModels

// MARK: - GetEditCommentParser (对应 Android GetEditCommentParser.java)
//
// 上游 2026-07-30「添加获取可编辑评论的功能」新增的接口。
// 编辑自己的评论时必须先取回**原始文本**(含 BBCode)，
// 直接拿列表里渲染过的 HTML 去编辑会把 BBCode 标记吃掉。
//
// 响应形如:
//   { "comment_id": 123456,
//     "editable_comment": "<textarea name=\"commenttext_edit\" …>原文</textarea>" }

public enum GetEditCommentParser {

    public static func parse(_ data: Data) throws -> EditableComment {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }

        // 服务端错误优先 (对齐 Android: 有 error 字段直接抛 EhException)
        if let error = json["error"] as? String {
            throw ParseError.server(error)
        }

        // comment_id 可能是数字或字符串
        let id: Int64
        if let n = json["comment_id"] as? NSNumber {
            id = n.int64Value
        } else if let s = json["comment_id"] as? String, let n = Int64(s) {
            id = n
        } else {
            throw ParseError.invalidJSON
        }

        guard let fragment = json["editable_comment"] as? String else {
            throw ParseError.commentNotFound
        }

        let doc = try SwiftSoup.parseBodyFragment(fragment)
        guard let textarea = try doc.select("textarea[name=commenttext_edit]").first() else {
            throw ParseError.commentNotFound
        }

        // 拼接子文本节点的 getWholeText(): 保留原始换行
        // (SwiftSoup 没有 Element.wholeText(); Element.text()/val() 会把换行折成空格，
        //  评论里的 BBCode 断行会被吃掉，所以必须逐个 TextNode 取原文)
        let comment = textarea.getChildNodes()
            .compactMap { ($0 as? TextNode)?.getWholeText() }
            .joined()
        return EditableComment(id: id, comment: ParserUtils.unescapeXml(comment))
    }

    public enum ParseError: LocalizedError {
        case invalidJSON
        case commentNotFound
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON:      return "无法解析可编辑评论响应"
            case .commentNotFound:  return "响应中找不到可编辑的评论内容"
            case .server(let msg):  return msg
            }
        }
    }
}
