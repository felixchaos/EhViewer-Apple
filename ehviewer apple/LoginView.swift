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

/// 登录方式 — 顺序即推荐顺序
private enum LoginMethod: String, Identifiable, CaseIterable {
    case web        // 内嵌浏览器
    case password   // 账号密码
    case cookie     // 粘贴 Cookie

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web:      return "网页登录"
        case .password: return "账号密码登录"
        case .cookie:   return "粘贴 Cookie 登录"
        }
    }

    /// 一句话说清"这个方式会发生什么 / 什么时候该用它"
    var blurb: String {
        switch self {
        case .web:      return "在应用内打开官网，可完成人机验证。"
        case .password: return "使用账号与密码登录。可能需要人机验证。"
        case .cookie:   return "从浏览器复制整段 Cookie 粘进来"
        }
    }

    var icon: String {
        switch self {
        case .web:      return "globe"
        case .password: return "person.text.rectangle"
        case .cookie:   return "doc.on.clipboard"
        }
    }
}


/// 凭据没能写进钥匙串时提醒用户。
///
/// 认证 Cookie 是会话 Cookie，钥匙串写失败 = 这次登录撑不过重启。
/// 不说的话，用户下次打开 App 只会看到自己莫名其妙退登了。
/// 三个登录入口（账号密码 / WebView / 手填 Cookie）共用。
@MainActor
private func warnIfCredentialsNotPersisted() {
    guard EhCookieManager.credentialPersistenceFailed else { return }
    EhCookieManager.credentialPersistenceFailed = false
    EhToast.failure("凭据未能保存，重启后可能需要重新登录")
}

struct LoginView: View {
    @Environment(AppState.self) private var appState

    @State private var method: LoginMethod?
    @State private var showGuestConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    brand
                    primaryAction
                    secondaryMethods
                    guestEntry
                    registerFooter
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle("登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $method) { method in
                switch method {
                case .web:      WebViewLoginView().environment(appState)
                case .password: PasswordLoginView().environment(appState)
                case .cookie:   CookieLoginView().environment(appState)
                }
            }
            .confirmationDialog(
                "以访客身份浏览？",
                isPresented: $showGuestConfirm,
                titleVisibility: .visible
            ) {
                Button("继续") { enterGuestMode() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("访客可浏览 E-Hentai。云端收藏、账号配额和 ExHentai 需要登录。可在设置中登录。")
            }
        }
    }

    // MARK: - 品牌区

    private var brand: some View {
        VStack(spacing: 10) {
            // 用真正的 App 图标而不是 SF Symbol。
            // AppIcon.appiconset 无法被 Image("AppIcon") 直接引用，
            // 因此在 Assets 里另存了一份普通图片集 AppLogo。
            Image("AppLogo")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(EhColor.cardStroke, lineWidth: 0.5)
                }

            VStack(spacing: 4) {
                Text("登录 E-Hentai")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(EhColor.label)
                Text("登录可同步收藏、发表评论和查看配额。ExHentai 还需账号访问权限。可使用访客模式。")
                    .font(EhFont.caption)
                    .foregroundStyle(EhColor.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 24)
    }

    // MARK: - 主推方式

    /// 网页登录放主位: 表单登录经常被 Cloudflare Turnstile 拦，
    /// 内嵌浏览器是唯一能稳定完成人机验证的路径
    private var primaryAction: some View {
        Button {
            method = .web
        } label: {
            HStack(spacing: 14) {
                Image(systemName: LoginMethod.web.icon)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(LoginMethod.web.title)
                            .font(.headline)
                        Text("推荐")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                    Text(LoginMethod.web.blurb)
                        .font(.caption)
                        .opacity(0.85)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.7)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(EhColor.onAccentFill)
        .padding(.horizontal, EhSpacing.page)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: EhRadius.card, style: .continuous)
                .fill(EhColor.accentFill)
        }
    }

    // MARK: - 其他方式

    private var secondaryMethods: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("其他方式")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach([LoginMethod.password, .cookie]) { item in
                    Button { method = item } label: {
                        methodRow(item)
                    }
                    .buttonStyle(.plain)

                    if item != .cookie { Divider().padding(.leading, 56) }
                }
            }
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func methodRow(_ item: LoginMethod) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(item.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 访客入口

    /// 以前是一行灰色 caption，看起来不像能点。
    /// 很多人只想逛 E-Hentai，这条路径值得一个真正的按钮。
    private var guestEntry: some View {
        Button {
            showGuestConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                Text("以访客身份浏览")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - 注册

    /// 单独隔开放最底部 —— 和上面的操作拉开距离，避免误触跳出 App
    private var registerFooter: some View {
        HStack(spacing: 4) {
            Text("还没有账号？")
                .foregroundStyle(.secondary)
            Link("前往注册", destination: URL(string: EhURL.registerUrl)!)
        }
        .font(.footnote)
        .padding(.top, 12)
    }

    private var rowBackground: some ShapeStyle {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func enterGuestMode() {
        // 游客模式: 强制 E-Hentai，无法访问 ExHentai
        AppSettings.shared.gallerySite = .eHentai
        AppSettings.shared.skipSignIn = true
        EhCookieManager.shared.injectNWCookie()
        // 不写 isSignedIn —— 访客没有登录，写成 true 会让「我的」显示「已登录」
        // 且拿不到登录入口。引导门禁读的是 AppState.canEnterApp。
        appState.checkLoginStatus()
        NotificationCenter.default.post(name: .ehGuestModeEntered, object: nil)
    }
}

// MARK: - 账号密码登录

struct PasswordLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var blockedByChallenge = false
    @State private var showWebFallback = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .disabled(isLoading)

                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .disabled(isLoading)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("登录的是 E-Hentai 论坛账号（forums.e-hentai.org）。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)

                        // 被人机验证拦下时给一条能走通的路，而不是只报错
                        if blockedByChallenge {
                            Button("改用网页登录") { showWebFallback = true }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("登录").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isLoading)
                }
            }
            .navigationTitle("账号密码登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showWebFallback) {
                WebViewLoginView().environment(appState)
            }
        }
    }

    /// 使用 EhAPI.signIn() + SignInParser 进行登录
    private func signIn() async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }
        let loginName = username
        do {
            _ = try await EhAPI.shared.signIn(username: loginName, password: password)
            let cookies = EhCookieManager.shared
            cookies.syncLoginCookies()
            cookies.injectNWCookie()
            let profile = AccountProfileStore.shared
            profile.synchronize()
            guard let memberID = profile.memberID else {
                errorMessage = "登录会话不可用。"
                return
            }
            profile.rememberLoginName(loginName, for: memberID)
            profile.broadcastSessionChange()
            AppSettings.shared.isLogin = true
            warnIfCredentialsNotPersisted()
            appState.checkLoginStatus()
            dismiss()
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
                    onLoginDetected: {
                        guard !loginDetected else { return }
                        loginDetected = true
                        AccountProfileStore.shared.beginImportedSession()
                        warnIfCredentialsNotPersisted()
                        AppSettings.shared.isLogin = true
                        appState.checkLoginStatus()
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

}

// MARK: - WKWebView 封装 (对齐 Android WebView Cookie 提取)

#if os(iOS)
struct WebViewLogin: UIViewRepresentable {
    @Binding var isLoading: Bool
    var onLoginDetected: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // An explicit login uses a fresh web session; an old WebKit cookie pair
        // must not silently restore an account after app sign-out.
        config.websiteDataStore = .nonPersistent()
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
        // WKWebView 的 cookie store 在 cookiesDidChange 通知时可能尚未完全提交，
        // 直接调用 getAllCookies 可能获取不到最新值，添加延迟确保 cookie 已写入
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !hasDetected, let webView = self.webView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.hasDetected else { return }
                self.checkForLoginCookies(webView: webView)
            }
        }

        private func checkForLoginCookies(webView: WKWebView) {
            guard !hasDetected else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let forumCookies = cookies.filter {
                    let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domain == "forums.e-hentai.org" || domain == "e-hentai.org"
                }
                guard let member = forumCookies.first(where: { $0.name == EhCookieManager.keyIPBMemberId })?.value,
                      let hash = forumCookies.first(where: { $0.name == EhCookieManager.keyIPBPassHash })?.value,
                      !member.isEmpty, !hash.isEmpty
                else { return }
                Task { @MainActor in
                    guard !self.hasDetected else { return }
                    self.hasDetected = true
                    await EhCookieManager.shared.applyImportedLogin(memberId: member, passHash: hash, igneous: nil)
                    self.parent.onLoginDetected()
                }
            }
        }
    }
}
#else
// macOS 使用 NSViewRepresentable
struct WebViewLogin: NSViewRepresentable {
    @Binding var isLoading: Bool
    var onLoginDetected: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // An explicit login uses a fresh web session; an old WebKit cookie pair
        // must not silently restore an account after app sign-out.
        config.websiteDataStore = .nonPersistent()
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
        // WKWebView 的 cookie store 在 cookiesDidChange 通知时可能尚未完全提交，
        // 添加延迟确保 cookie 已写入
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !hasDetected, let webView = self.webView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.hasDetected else { return }
                self.checkForLoginCookies(webView: webView)
            }
        }

        private func checkForLoginCookies(webView: WKWebView) {
            guard !hasDetected else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let forumCookies = cookies.filter {
                    let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domain == "forums.e-hentai.org" || domain == "e-hentai.org"
                }
                guard let member = forumCookies.first(where: { $0.name == EhCookieManager.keyIPBMemberId })?.value,
                      let hash = forumCookies.first(where: { $0.name == EhCookieManager.keyIPBPassHash })?.value,
                      !member.isEmpty, !hash.isEmpty
                else { return }
                Task { @MainActor in
                    guard !self.hasDetected else { return }
                    self.hasDetected = true
                    await EhCookieManager.shared.applyImportedLogin(memberId: member, passHash: hash, igneous: nil)
                    self.parent.onLoginDetected()
                }
            }
        }
    }
}
#endif

// MARK: - Cookie 登录

/// 从任意文本里抠出 EhViewer 需要的三个 Cookie
///
/// 用户从浏览器拿到的东西格式五花八门，都要能直接粘：
///   `ipb_member_id=123; ipb_pass_hash=abc; igneous=xyz`   ← 开发者工具 / document.cookie
///   `Cookie: ipb_member_id=123; ...`                       ← 复制请求头
///   `ipb_member_id: 123`                                   ← 手抄
///   `{"name":"ipb_member_id","value":"123"}`               ← Cookie 导出插件的 JSON
enum EhCookieTextParser {

    struct Result: Equatable {
        var memberId: String?
        var passHash: String?
        var igneous: String?

        /// 登录只需要前两个，igneous 只影响 ExHentai
        var isUsable: Bool { memberId?.isEmpty == false && passHash?.isEmpty == false }
    }

    private static let keys = ["ipb_member_id", "ipb_pass_hash", "igneous"]

    /// `name=value` / `name: value`，允许引号包裹
    private static let inlinePattern = try! NSRegularExpression(
        pattern: #"(ipb_member_id|ipb_pass_hash|igneous)["']?\s*[:=]\s*["']?([^;,\s"'}\]]+)"#,
        options: [.caseInsensitive]
    )

    /// Cookie 导出插件的 JSON: {"name": "...", "value": "..."}
    private static let jsonPattern = try! NSRegularExpression(
        pattern: #""name"\s*:\s*"(ipb_member_id|ipb_pass_hash|igneous)"\s*,\s*"value"\s*:\s*"([^"]*)""#,
        options: [.caseInsensitive]
    )

    static func parse(_ raw: String) -> Result {
        var result = Result()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return result }

        // JSON 形式优先 —— 它的 name/value 结构比裸 name=value 更可靠
        for regex in [jsonPattern, inlinePattern] {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text),
                      let valRange = Range(match.range(at: 2), in: text) else { continue }
                let key = String(text[keyRange]).lowercased()
                let value = String(text[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }

                switch key {
                case "ipb_member_id": if result.memberId == nil { result.memberId = value }
                case "ipb_pass_hash": if result.passHash == nil { result.passHash = value }
                case "igneous":
                    // 未开通 ExHentai 时服务端会下发 igneous=mystery，存了反而有害
                    if result.igneous == nil, value.lowercased() != "mystery" { result.igneous = value }
                default: break
                }
            }
            if result.isUsable { break }
        }
        return result
    }

    /// 文本里是否出现过我们认识的 key —— 用来区分"粘错了东西"和"格式没解析出来"
    static func mentionsAnyKey(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return keys.contains { lower.contains($0) }
    }
}

struct CookieLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var showManualFields = false
    @State private var manualMemberId = ""
    @State private var manualPassHash = ""
    @State private var manualIgneous = ""
    @State private var isApplying = false

    /// 粘贴框解析结果；手动模式下用手填的值
    private var parsed: EhCookieTextParser.Result {
        if showManualFields {
            return .init(
                memberId: manualMemberId.isEmpty ? nil : manualMemberId,
                passHash: manualPassHash.isEmpty ? nil : manualPassHash,
                igneous:  manualIgneous.isEmpty  ? nil : manualIgneous
            )
        }
        return EhCookieTextParser.parse(pasted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $pasted)
                            .frame(minHeight: 96)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        if pasted.isEmpty {
                            Text("在这里粘贴整段 Cookie\nipb_member_id=…; ipb_pass_hash=…; igneous=…")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                    // 用系统 PasteButton：它自带授权语义，不会每次弹"允许粘贴吗"
                    #if os(iOS)
                    PasteButton(payloadType: String.self) { items in
                        guard let text = items.first else { return }
                        Task { @MainActor in pasted = text }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    #else
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    #endif
                } header: {
                    Text("粘贴 Cookie")
                } footer: {
                    Text("可粘贴分号分隔的 Cookie、Cookie 请求头或导出插件生成的 JSON，无需拆分。")
                }

                // 实时解析反馈 —— 粘完立刻知道认没认出来
                if !pasted.isEmpty && !showManualFields {
                    Section("识别结果") {
                        detectedRow("ipb_member_id", parsed.memberId, required: true)
                        detectedRow("ipb_pass_hash", parsed.passHash, required: true)
                        detectedRow("igneous", parsed.igneous, required: false)

                        if !parsed.isUsable {
                            Text(EhCookieTextParser.mentionsAnyKey(pasted)
                                 ? "检测到字段名，未检测到值。检查复制内容。"
                                 : "没找到 ipb_member_id / ipb_pass_hash，可能粘错了内容。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    DisclosureGroup("手动填写", isExpanded: $showManualFields) {
                        TextField("ipb_member_id", text: $manualMemberId)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("ipb_pass_hash", text: $manualPassHash)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("igneous (仅 ExHentai)", text: $manualIgneous)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    .font(.system(.body, design: .monospaced))
                } footer: {
                    Text("登录 e-hentai.org 后，在「开发者工具 → 应用 → Cookie」复制以下字段。")
                }

                Section {
                    Button {
                        Task { await applyCookies() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("导入 Cookie").bold()
                            Spacer()
                        }
                    }
                    .disabled(!parsed.isUsable || isApplying)
                } footer: {
                    Text("凭据仅保存在本机钥匙串，不同步至 iCloud、不随备份迁移，也不上传给第三方。ExHentai 可能要求有效的 igneous。")
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

    private func detectedRow(_ name: String, _ value: String?, required: Bool) -> some View {
        HStack {
            Image(systemName: value == nil ? (required ? "xmark.circle" : "minus.circle") : "checkmark.circle.fill")
                .foregroundStyle(value == nil ? (required ? Color.red : Color.secondary) : Color.green)
            Text(name)
                .font(.system(.footnote, design: .monospaced))
            Spacer()
            Text(value.map(masked) ?? (required ? "未识别" : "未提供"))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// 凭据只回显首尾，避免录屏 / 截图泄露
    private func masked(_ value: String) -> String {
        guard value.count > 6 else { return String(repeating: "•", count: value.count) }
        return value.prefix(3) + String(repeating: "•", count: 4) + value.suffix(2)
    }

    #if os(macOS)
    private func pasteFromClipboard() {
        pasted = NSPasteboard.general.string(forType: .string) ?? pasted
    }
    #endif

    private func applyCookies() async {
        let cookies = parsed
        guard !isApplying, let memberId = cookies.memberId, let passHash = cookies.passHash else { return }
        isApplying = true
        defer { isApplying = false }
        await EhCookieManager.shared.applyImportedLogin(memberId: memberId, passHash: passHash,
                                                        igneous: cookies.igneous)
        AccountProfileStore.shared.beginImportedSession()
        warnIfCredentialsNotPersisted()
        AppSettings.shared.isLogin = true
        appState.checkLoginStatus()
        dismiss()
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
