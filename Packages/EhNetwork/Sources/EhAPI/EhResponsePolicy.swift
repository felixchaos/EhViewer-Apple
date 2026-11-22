import Foundation

/// Classifies an already received response without touching cookies, sending
/// notifications or accessing the network. EhAPI owns those side effects.
enum EhResponsePolicy {
    static func failure(for response: URLResponse, data: Data, requestUrl: String? = nil) -> EhError? {
        guard let response = response as? HTTPURLResponse else {
            return .networkError("Invalid response")
        }

        // Keep all three headers: guessing from a single image header could
        // invalidate credentials for an ordinary image request.
        if response.value(forHTTPHeaderField: "Content-Disposition") == "inline; filename=\"sadpanda.jpg\"",
           response.value(forHTTPHeaderField: "Content-Type") == "image/gif",
           response.value(forHTTPHeaderField: "Content-Length") == "9615" {
            return .sadPanda
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("https://exhentai.org/img/kokomade.jpg") {
            return .kokomade
        }

        if let detail = ipBanDetail(from: body) {
            return .ipBanned(detail)
        }

        if response.statusCode == 200,
           let url = requestUrl,
           (url == "https://exhentai.org/" || url == "https://exhentai.org"),
           body.isEmpty {
            return .igneousWrong
        }

        if response.statusCode >= 400 {
            return .httpError(response.statusCode, body)
        }

        return nil
    }

    private static func ipBanDetail(from body: String) -> String? {
        let lowered = body.lowercased()
        guard lowered.contains("your ip address has been temporarily banned")
                || lowered.contains("temporarily banned from")
                || lowered.contains("banned for excessive pageloads") else {
            return nil
        }
        if let range = body.range(of: #"[Ee]xpires? in[^.<]*"#, options: .regularExpression) {
            return String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
