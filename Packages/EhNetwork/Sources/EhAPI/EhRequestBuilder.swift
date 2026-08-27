import Foundation

// MARK: - HTTP 请求构建 (对应 Android EhRequestBuilder.java)
// 统一 User-Agent / Accept / Accept-Language 等伪装 Header

public enum EhRequestBuilder {

    // MARK: 固定 Header (模拟 Chrome 浏览器)

    public static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"

    /// HTML 页面请求 Accept (模拟浏览器默认)
    public static let acceptHTML =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"

    /// 图片请求 Accept
    public static let acceptImage =
        "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"

    /// JSON API 请求 Accept
    public static let acceptJSON =
        "application/json, */*;q=0.8"

    public static let acceptLanguage =
        "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7"

    /// 构建标准 GET 请求
    public static func buildGetRequest(
        url: URL,
        referer: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: cachePolicy)
        request.httpMethod = "GET"
        applyCommonHeaders(&request, referer: referer)
        return request
    }

    /// 构建 POST JSON 请求
    public static func buildPostJSONRequest(
        url: URL,
        json: Data,
        referer: String? = nil,
        origin: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        applyCommonHeaders(&request, referer: referer)
        return request
    }

    /// 构建 POST Form 请求
    /// 使用 RFC 3986 严格编码 (对齐 OkHttp FormBody 行为)
    public static func buildPostFormRequest(
        url: URL,
        formFields: [(String, String)],
        referer: String? = nil,
        origin: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body = formFields.map { "\(formURLEncode($0.0))=\(formURLEncode($0.1))" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        applyCommonHeaders(&request, referer: referer)
        return request
    }

    /// application/x-www-form-urlencoded 编码 (对齐 OkHttp FormBody)
    /// 空格编码为 +, 保留字符全部 percent-encode
    private static func formURLEncode(_ string: String) -> String {
        // 仅允许: 字母 / 数字 / - _ . *
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.*")
        return string
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+")
            ?? string
    }

    /// 构建 Multipart/form-data POST 请求 (用于以图搜图等)
    /// 对应 Android OkHttp MultipartBody.Builder
    public static func buildMultipartRequest(
        url: URL,
        parts: [MultipartPart],
        referer: String? = nil,
        origin: String? = nil
    ) -> URLRequest {
        let boundary = "----WebKitFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }

        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(part.name)\"".data(using: .utf8)!)
            if let filename = part.filename {
                body.append("; filename=\"\(filename)\"".data(using: .utf8)!)
            }
            body.append("\r\n".data(using: .utf8)!)
            if let contentType = part.contentType {
                body.append("Content-Type: \(contentType)\r\n".data(using: .utf8)!)
            }
            body.append("\r\n".data(using: .utf8)!)
            body.append(part.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        applyCommonHeaders(&request, referer: referer)
        return request
    }

    /// 构建 URL-encoded POST 请求 (Content-Type: application/x-www-form-urlencoded, raw body string)
    /// 用于 addTag / deleteWatchedTag 等直接传 raw body 的场景
    public static func buildPostRawFormRequest(
        url: URL,
        rawBody: String,
        referer: String? = nil,
        origin: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = rawBody.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        applyCommonHeaders(&request, referer: referer)
        return request
    }

    // MARK: Private

    private static func applyCommonHeaders(_ request: inout URLRequest, referer: String?) {
        // 不手动设置 Host header — URLSession 自动处理, 手动设置可能干扰反代/CDN
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // 根据请求类型选择 Accept header
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("application/json") {
            request.setValue(acceptJSON, forHTTPHeaderField: "Accept")
        } else if request.httpMethod == "GET" {
            request.setValue(acceptHTML, forHTTPHeaderField: "Accept")
        } else {
            request.setValue(acceptHTML, forHTTPHeaderField: "Accept")
        }
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
    }

    /// 构建图片请求 (使用图片 Accept header)
    public static func buildImageRequest(
        url: URL,
        referer: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptImage, forHTTPHeaderField: "Accept")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }
}

// MARK: - Multipart 部分

public struct MultipartPart: Sendable {
    public var name: String
    public var filename: String?
    public var contentType: String?
    public var data: Data

    public init(name: String, data: Data, filename: String? = nil, contentType: String? = nil) {
        self.name = name; self.data = data
        self.filename = filename; self.contentType = contentType
    }

    /// 纯文本部分
    public static func text(name: String, value: String) -> MultipartPart {
        MultipartPart(name: name, data: value.data(using: .utf8)!)
    }

    /// 文件部分
    public static func file(name: String, filename: String, data: Data, contentType: String = "application/octet-stream") -> MultipartPart {
        MultipartPart(name: name, data: data, filename: filename, contentType: contentType)
    }
}
