import Foundation

// MARK: - 解析工具 (对应 Android ParserUtils.java)
// 提供日期格式化、安全解析数字、HTML 实体解码等

public enum ParserUtils {

    /// 日期格式 (对应 Android "yyyy-MM-dd HH:mm")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 格式化时间戳 (秒) 为 "yyyy-MM-dd HH:mm"
    public static func formatDate(_ timestamp: Int64) -> String {
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// 清理字符串：解码 HTML 实体 + trim (对应 Android ParserUtils.trim → StringUtils.unescapeXml)
    public static func trim(_ str: String?) -> String {
        guard let str = str else { return "" }
        return unescapeXml(str).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 安全解析 Int，忽略逗号分隔符 (对应 Android ParserUtils.parseInt)
    public static func parseInt(_ str: String?, defaultValue: Int = 0) -> Int {
        guard let str = str else { return defaultValue }
        let cleaned = trim(str).replacingOccurrences(of: ",", with: "")
        return Int(cleaned) ?? defaultValue
    }

    /// 安全解析 Int64 (对应 Android ParserUtils.parseLong)
    public static func parseLong(_ str: String?, defaultValue: Int64 = 0) -> Int64 {
        guard let str = str else { return defaultValue }
        let cleaned = trim(str).replacingOccurrences(of: ",", with: "")
        return Int64(cleaned) ?? defaultValue
    }

    /// 安全解析 Float (对应 Android ParserUtils.parseFloat)
    public static func parseFloat(_ str: String?, defaultValue: Float = 0) -> Float {
        guard let str = str else { return defaultValue }
        let cleaned = trim(str).replacingOccurrences(of: ",", with: "")
        return Float(cleaned) ?? defaultValue
    }

    // MARK: - HTML 实体解码

    /// 数字实体正则 &#xxxx; (预编译，避免每次调用 unescapeXml 重新创建)
    private static let numericEntityRegex = try! NSRegularExpression(pattern: #"&#(\d+);"#)
    /// 十六进制实体正则 &#xHHHH;
    private static let hexEntityRegex = try! NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#)

    /// 解码 HTML/XML 实体 (对应 Android StringUtils.unescapeXml)
    public static func unescapeXml(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&#039;", with: "'")
        // 数字实体 &#xxxx;
        let nsResult = result as NSString
        let matches = numericEntityRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
        for match in matches.reversed() {
            if let range = Range(match.range, in: result),
               let codeRange = Range(match.range(at: 1), in: result),
               let code = UInt32(result[codeRange]),
               let scalar = Unicode.Scalar(code) {
                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        // 十六进制 &#xHHHH;
        let nsResult2 = result as NSString
        let hexMatches = hexEntityRegex.matches(in: result, range: NSRange(location: 0, length: nsResult2.length))
        for match in hexMatches.reversed() {
            if let range = Range(match.range, in: result),
               let codeRange = Range(match.range(at: 1), in: result),
               let code = UInt32(result[codeRange], radix: 16),
               let scalar = Unicode.Scalar(code) {
                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return result
    }
}
