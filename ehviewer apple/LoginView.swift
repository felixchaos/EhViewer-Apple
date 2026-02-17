//
//  LoginView.swift
//  ehviewer apple
//
//  登录界面 — E-Hentai Forums 认证
//  对齐 Android: 账号密码登录 / WebView 登录 / Cookie 登录 / 跳过登录
//

import SwiftUI
import EhSettings
import EhAPI
import EhCookie
import EhParser
import WebKit

struct LoginView: View {
    @Environment(AppState.self) private var appState

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCookieLogin = false
    @State private var showWebViewLogin = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Logo
                    VStack(spacing: 8) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                        Text("EhViewer")
                            .font(.largeTitle.bold())
                        Text("E-Hentai / ExHentai Gallery Browser")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    // 登录表单
                    VStack(spacing: 16) {
                        TextField("用户名", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                            .disabled(isLoading)

                        SecureField("密码", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .disabled(isLoading)
                            .onSubmit { Task { await signIn() } }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button(action: { Task { await signIn() } }) {
                            Group {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("登录")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(username.isEmpty || password.isEmpty || isLoading)
                    }
                    .frame(maxWidth: 360)

                    // 替代登录方式
                    VStack(spacing: 12) {
                        Divider()

                        // WebView 登录 (对齐 Android: 网页登录)
                        Button("网页登录") {
                            showWebViewLogin = true
                        }
                        .buttonStyle(.bordered)

                        Button("Cookie 登录") {
                            showCookieLogin = true
                        }
                        .buttonStyle(.bordered)

                        Button("跳过登录 (仅 E-Hentai)") {
                            // 游客模式: 强制使用 E-Hentai 站点，不能访问 ExHentai
                            AppSettings.shared.gallerySite = .eHentai
                            AppSettings.shared.skipSignIn = true
                            EhCookieManager.shared.injectNWCookie()
                            appState.isSignedIn = true
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Link("注册账号", destination: URL(string: EhURL.registerUrl)!)
                            .font(.caption)
                    }
                    .frame(maxWidth: 360)
                }
                .padding()
            }
            .navigationTitle("登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showCookieLogin) {
                CookieLoginView()
                    .environment(appState)
            }
            .sheet(isPresented: $showWebViewLogin) {
                WebViewLoginView()
                    .environment(appState)
            }
        }
    }

    /// 使用 EhAPI.signIn() + SignInParser 进行登录
    private func signIn() async {
        isLoading = true
        errorMessage = nil

        do {
            // 使用 EhAPI 统一的 signIn 方法 (内部使用 EhRequestBuilder + SignInParser)
            let displayName = try await EhAPI.shared.signIn(username: username, password: password)

            // 登录成功 — 同步 Cookie 到 ExHentai
            EhCookieManager.shared.syncLoginCookies()
            EhCookieManager.shared.injectNWCookie()

            // 保存用户信息
            AppSettings.shared.isLogin = true
            AppSettings.shared.displayName = displayName

            // 保存 UID
            if let uid = EhCookieManager.shared.memberId {
                AppSettings.shared.userId = uid
            }

            // 异步获取完整用户资料 (avatar 等) — RootView 统一处理

            appState.isSignedIn = true
        } catch let error as EhParseError {
            switch error {
            case .signInError(let msg):
                errorMessage = msg
            case .parseFailure(let msg):
                errorMessage = "解析失败: \(msg)"
            }
        } catch let ehError as EhError {
            if case .cloudflare403 = ehError {
                errorMessage = ehError.localizedDescription
            } else {
                errorMessage = "网络错误: \(ehError.localizedDescription)"
            }
        } catch {
            errorMessage = "网络错误: \(error.localizedDescription)"
        }

        isLoading = false
    }

}

// MARK: - WebView 登录 (对齐 Android WebView 登录方式)

struct WebViewLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var loginDetected = false

    var body: some View {
        NavigationStack {
            ZStack {
                WebViewLogin(
                    isLoading: $isLoading,
                    onLoginDetected: { displayName in
                        guard !loginDetected else { return }
                        loginDetected = true

                        // 同步 Cookie
                        EhCookieManager.shared.syncLoginCookies()
                        EhCookieManager.shared.injectNWCookie()

                        // 保存登录状态
                        AppSettings.shared.isLogin = true
                        if let name = displayName, !name.isEmpty {
                            AppSettings.shared.displayName = name
                        }

                        // 保存 UID (ipb_member_id)
                        if let uid = EhCookieManager.shared.memberId {
                            AppSettings.shared.userId = uid
                        }

                        // 登录后异步获取用户资料 + ExH 检测
                        Task {
                            await postLoginSetup()
                        }

                        appState.isSignedIn = true
                        dismiss()
                    }
                )

                if isLoading {
                    ProgressView("加载中...")
                }
            }
            .navigationTitle("网页登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    /// 登录后的异步设置：获取用户资料
    /// ExH 检测由 RootView 统一处理
    private func postLoginSetup() async {
        // 获取用户资料 (displayName, avatar)
        do {
            let profile = try await EhAPI.shared.getProfile()
            if let name = profile.displayName {
                AppSettings.shared.displayName = name
            }
            if let avatar = profile.avatar {
                AppSettings.shared.avatar = avatar
            }
        } catch {
            debugLog("[WebViewLogin] 获取用户资料失败: \(error)")
        }
    }
}

// MARK: - WKWebView 封装 (对齐 Android WebView Cookie 提取)

#if os(iOS)
struct WebViewLogin: UIViewRepresentable {
    @Binding var isLoading: Bool
    var onLoginDetected: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // 使用 iOS Safari 原生 UA — Cloudflare Turnstile 需要真实浏览器 UA

        // 监听 Cookie 变化 — 登录成功后 Cookie 被设置时立即检测
        config.websiteDataStore.httpCookieStore.add(context.coordinator)

        // 加载论坛登录页面
        if let url = URL(string: EhURL.signInReferer) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let parent: WebViewLogin
        private var hasDetected = false
        private weak var webView: WKWebView?

        init(_ parent: WebViewLogin) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.isLoading = false
            checkForLoginCookies(webView: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.webView = webView
            parent.isLoading = true
        }

        // WKHTTPCookieStoreObserver — Cookie 变化时自动触发
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !hasDetected, let webView = self.webView else { return }
            checkForLoginCookies(webView: webView)
        }

        private func checkForLoginCookies(webView: WKWebView) {
            guard !hasDetected else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var memberId: String?
                var passHash: String?

                for cookie in cookies {
                    if cookie.name == "ipb_member_id" {
                        memberId = cookie.value
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    if cookie.name == "ipb_pass_hash" {
                        passHash = cookie.value
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    if cookie.name == "igneous" || cookie.name == "sk" || cookie.name == "star" {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                }

                if memberId != nil && passHash != nil {
                    self.hasDetected = true
                    // 尝试从页面提取用户名
                    webView.evaluateJavaScript(
                        "document.querySelector('#userlinks .home b')?.textContent || document.querySelector('.home b')?.textContent || ''"
                    ) { result, _ in
                        let name = result as? String
                        DispatchQueue.main.async {
                            self.parent.onLoginDetected(name?.isEmpty == true ? nil : name)
                        }
                    }
                }
            }
        }
    }
}
#else
// macOS 使用 NSViewRepresentable
struct WebViewLogin: NSViewRepresentable {
    @Binding var isLoading: Bool
    var onLoginDetected: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // 使用 macOS Safari 原生 UA — Cloudflare Turnstile 需要真实浏览器 UA

        // 监听 Cookie 变化
        config.websiteDataStore.httpCookieStore.add(context.coordinator)

        if let url = URL(string: EhURL.signInReferer) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let parent: WebViewLogin
        private var hasDetected = false
        private weak var webView: WKWebView?

        init(_ parent: WebViewLogin) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.isLoading = false
            checkForLoginCookies(webView: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.webView = webView
            parent.isLoading = true
        }

        // WKHTTPCookieStoreObserver — Cookie 变化时自动触发
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !hasDetected, let webView = self.webView else { return }
            checkForLoginCookies(webView: webView)
        }

        private func checkForLoginCookies(webView: WKWebView) {
            guard !hasDetected else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var memberId: String?
                var passHash: String?

                for cookie in cookies {
                    if cookie.name == "ipb_member_id" {
                        memberId = cookie.value
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    if cookie.name == "ipb_pass_hash" {
                        passHash = cookie.value
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    if cookie.name == "igneous" || cookie.name == "sk" || cookie.name == "star" {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                }

                if memberId != nil && passHash != nil {
                    self.hasDetected = true
                    webView.evaluateJavaScript(
                        "document.querySelector('#userlinks .home b')?.textContent || document.querySelector('.home b')?.textContent || ''"
                    ) { result, _ in
                        let name = result as? String
                        DispatchQueue.main.async {
                            self.parent.onLoginDetected(name?.isEmpty == true ? nil : name)
                        }
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Cookie 手动登录

struct CookieLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var memberId = ""
    @State private var passHash = ""
    @State private var igneous = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("必填") {
                    TextField("ipb_member_id", text: $memberId)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                    TextField("ipb_pass_hash", text: $passHash)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                }
                Section("可选 (ExHentai)") {
                    TextField("igneous", text: $igneous)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                }
                Section {
                    Button("确认登录") {
                        applyCookies()
                    }
                    .disabled(memberId.isEmpty || passHash.isEmpty)
                }
            }
            .navigationTitle("Cookie 登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func applyCookies() {
        // 使用 EhCookieManager 统一设置 Cookie
        let cookieManager = EhCookieManager.shared

        for domain in [EhCookieManager.domainEhentai, EhCookieManager.domainExhentai] {
            cookieManager.setCookie(name: EhCookieManager.keyIPBMemberId, value: memberId, domain: domain)
            cookieManager.setCookie(name: EhCookieManager.keyIPBPassHash, value: passHash, domain: domain)
        }

        // 注入 nw=1 跳过内容警告
        cookieManager.injectNWCookie()

        // igneous (ExHentai 权限 Cookie)
        if !igneous.isEmpty {
            cookieManager.setCookie(name: EhCookieManager.keyIgneous, value: igneous, domain: EhCookieManager.domainExhentai)
        }

        // 保存登录状态
        AppSettings.shared.isLogin = true
        appState.isSignedIn = true
        dismiss()
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
