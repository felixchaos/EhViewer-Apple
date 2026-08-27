//
//  EhNewsView.swift
//  ehviewer apple
//
//  E-Hentai 站内新闻 / 活动公告 — 对齐 Android NewsScene
//
//  `getEhNews()` 和 EhEventParser 都早就在了，只是一直没有入口。
//  返回的是一段 HTML 片段，这里用 WebView 原样渲染 —— 公告里有表格、
//  链接和活动倒计时，转成纯文本会丢掉一半信息。
//

import SwiftUI
import EhModels
import EhAPI
import WebKit

struct EhNewsView: View {
    @State private var html: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("读取公告…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("读不到公告", systemImage: "newspaper")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if let html, !html.isEmpty {
                NewsWebView(html: html)
            } else {
                ContentUnavailableView(
                    "暂无公告",
                    systemImage: "newspaper",
                    description: Text("E-Hentai 目前没有发布新的站内公告。")
                )
            }
        }
        .navigationTitle("站内公告")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            html = try await EhAPI.shared.getEhNews().rawHtml
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
        isLoading = false
    }
}

/// 把公告 HTML 片段包一层可读的样式再渲染
private struct NewsWebView {
    let html: String

    var document: String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: -apple-system-body;
            font-family: -apple-system, "PingFang SC", sans-serif;
            margin: 16px; line-height: 1.6;
            color: #111; background: #fff;
            -webkit-text-size-adjust: 100%;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #eee; background: #000; }
            a { color: #6cb6ff; }
          }
          img { max-width: 100%; height: auto; }
          table { width: 100%; border-collapse: collapse; overflow-x: auto; display: block; }
          td, th { padding: 4px 6px; border: 1px solid rgba(128,128,128,.35); }
        </style>
        </head><body>\(html)</body></html>
        """
    }
}

#if os(iOS)
extension NewsWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(document, baseURL: URL(string: "https://e-hentai.org/"))
    }
}
#else
extension NewsWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { WKWebView() }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(document, baseURL: URL(string: "https://e-hentai.org/"))
    }
}
#endif
