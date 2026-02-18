//
//  RootView.swift
//  ehviewer apple
//
//  Root navigation: Warning → Security → SiteSelection → Login → Main app
//

import SwiftUI
import EhSettings
import EhAPI
import EhCookie

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 根视图: 引导流程控制器
/// 流程: 18+警告 → 安全认证 → 站点选择 → 登录检查 → 主界面
struct RootView: View {
    @State private var appState = AppState()
    @State private var flowStep: OnboardingStep = .checking
    
    /// 后台进入时间戳，用于判断是否需要重新认证
    @State private var backgroundTime: Date?
    
    /// 剪贴板画廊检测 (对齐 Android MainActivity.onResume 检测 EH 链接)
    @State private var clipboardGallery: (gid: Int64, token: String)?
    @State private var showClipboardAlert = false
    @State private var lastClipboardContent: String?

    /// ExHentai 切换提示
    @State private var showExHAlert = false

    /// Sad Panda / igneous 失效警告 (V-15)
    @State private var showSadPandaAlert = false
    /// 磁盘空间不足警告
    @State private var showDiskFullAlert = false
    enum OnboardingStep {
        case checking      // 检查状态中
        case warning       // 18+ 警告
        case rejected      // 拒绝 18+ 警告 (iOS 不能 exit, 显示永久阻断页)
        case security      // 安全认证
        case selectSite    // 站点选择
        case login         // 登录页
        case main          // 主界面
    }

    var body: some View {
        Group {
            switch flowStep {
            case .checking:
                Color.clear
                    .task { determineNextStep() }
                
            case .warning:
                WarningView(
                    onAccept: {
                        AppSettings.shared.showWarning = false
                        determineNextStep()
                    },
                    onReject: {
                        // macOS: 正常退出; iOS: 显示永久阻断页面 (Apple 禁止 exit(0))
                        #if os(macOS)
                        NSApplication.shared.terminate(nil)
                        #else
                        flowStep = .rejected
                        #endif
                    }
                )
                
            case .security:
                SecurityView(onAuthenticated: {
                    determineNextStep()
                })
                
            case .rejected:
                // iOS: 用户拒绝 18+ 警告后显示此页面，无法继续使用
                VStack(spacing: 20) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("您已拒绝使用条款")
                        .font(.title2.bold())
                    Text("请关闭应用。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .selectSite:
                SelectSiteView(onComplete: {
                    determineNextStep()
                })
                
            case .login:
                LoginView()
                    .environment(appState)
                
            case .main:
                MainTabView()
                    .environment(appState)
            }
        }
        .withGlobalErrorBoundary()
        .animation(.easeInOut, value: flowStep)
        .onChange(of: appState.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                flowStep = .main
                // 登录后异步任务：获取资料 + ExH 检测
                if !AppSettings.shared.skipSignIn {
                    Task { await postLoginActions() }
                }
            }
        }
        .alert("ExHentai 可用", isPresented: $showExHAlert) {
            Button("切换到 ExHentai") {
                AppSettings.shared.gallerySite = .exHentai
            }
            Button("保持 E-Hentai", role: .cancel) {}
        } message: {
            Text("检测到你的账号拥有 ExHentai 访问权限，是否切换到 ExHentai？")
        }
        // Sad Panda / igneous 失效警告 (V-15)
        .onReceive(NotificationCenter.default.publisher(for: .ehSadPandaDetected)) { _ in
            showSadPandaAlert = true
        }
        // 磁盘空间不足警告
        .onReceive(NotificationCenter.default.publisher(for: .ehDiskFull)) { _ in
            showDiskFullAlert = true
        }
        .alert("磁盘空间不足", isPresented: $showDiskFullAlert) {
            Button("我知道了", role: .cancel) {}
        } message: {
            Text("磁盘剩余空间不足，所有下载已自动暂停。\n请前往系统设置释放存储空间后，手动恢复下载。")
        }
        .alert("ExHentai 访问失效", isPresented: $showSadPandaAlert) {
            Button("重新登录") {
                AppSettings.shared.gallerySite = .eHentai
                appState.isSignedIn = false
                flowStep = .login
            }
            Button("切换到 E-Hentai", role: .cancel) {
                AppSettings.shared.gallerySite = .eHentai
            }
        } message: {
            Text("igneous Cookie 已失效 (Sad Panda)，已自动清除。\n请重新登录以恢复 ExHentai 访问权限，或切换到 E-Hentai。")
        }
        // 对齐 Android: 深色模式支持 (Settings.KEY_THEME)
        // 0=跟随系统, 1=浅色, 2=深色
        .preferredColorScheme(preferredColorScheme)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 记录进入后台的时间
            backgroundTime = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 检查是否需要重新认证
            checkSecurityOnResume()
            // 检查剪贴板中的画廊链接 (对齐 Android MainActivity.onResume)
            checkClipboardForGalleryUrl()
        }
        #elseif os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            backgroundTime = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkSecurityOnResume()
            checkClipboardForGalleryUrl()
        }
        #endif
        .alert("检测到画廊链接", isPresented: $showClipboardAlert) {
            Button("打开") {
                if let gallery = clipboardGallery {
                    NotificationCenter.default.post(
                        name: .openGalleryFromClipboard,
                        object: nil,
                        userInfo: ["gid": gallery.gid, "token": gallery.token]
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let gallery = clipboardGallery {
                Text("剪贴板含有画廊链接 (GID: \(gallery.gid))，是否打开？")
            }
        }
    }
    
    // MARK: - 流程控制

    /// 登录后异步操作：获取用户资料 + ExH 检测
    private func postLoginActions() async {
        // 1. 保存 UID
        if let uid = EhCookieManager.shared.memberId {
            AppSettings.shared.userId = uid
        }

        // 2. 获取用户资料
        do {
            let profile = try await EhAPI.shared.getProfile()
            if let name = profile.displayName {
                AppSettings.shared.displayName = name
            }
            if let avatar = profile.avatar {
                AppSettings.shared.avatar = avatar
            }
        } catch {
            debugLog("[RootView] 获取用户资料失败: \(error)")
        }

        // 3. ExH 可达性检测
        do {
            guard let url = URL(string: "https://exhentai.org/") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(EhRequestBuilder.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let config = URLSessionConfiguration.default
            config.httpCookieStorage = .shared
            let exSession = URLSession(configuration: config)
            let (data, response) = try await exSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200, data.count >= 1000 {
                // ExHentai 可访问 — 提示切换
                showExHAlert = true
            }
        } catch {
            debugLog("[RootView] ExHentai 检测失败: \(error)")
        }
    }

    /// 深色模式偏好 (对齐 Android: Settings.KEY_THEME)
    private var preferredColorScheme: ColorScheme? {
        switch AppSettings.shared.theme {
        case 1: return .light
        case 2: return .dark
        default: return nil // 0: 跟随系统
        }
    }
    
    private func determineNextStep() {
        let settings = AppSettings.shared
        
        // 1. 检查 18+ 警告
        if settings.showWarning {
            flowStep = .warning
            return
        }
        
        // 2. 检查安全认证 (仅在启用时)
        if settings.enableSecurity && flowStep != .security {
            // 首次进入或从后台恢复需要认证
            if flowStep == .checking {
                flowStep = .security
                return
            }
        }
        
        // 3. 检查站点选择
        if !settings.hasSelectedSite {
            flowStep = .selectSite
            return
        }
        
        // 4. 检查登录状态
        appState.checkLoginStatus()
        
        // 如果设置了跳过登录 (游客模式)，直接进入主界面
        if appState.isSignedIn || AppSettings.shared.skipSignIn {
            appState.isSignedIn = true  // 确保状态一致
            flowStep = .main
        } else {
            flowStep = .login
        }
    }
    
    private func checkSecurityOnResume() {
        guard AppSettings.shared.enableSecurity else { return }
        guard flowStep == .main || flowStep == .login else { return }
        
        // 检查是否超过安全延迟时间
        if let bgTime = backgroundTime {
            let delaySeconds = AppSettings.shared.securityDelay
            let elapsed = Date().timeIntervalSince(bgTime)
            
            if elapsed > Double(delaySeconds) {
                flowStep = .security
            }
        }
        
        backgroundTime = nil
    }

    /// 检查剪贴板中的画廊链接 (对齐 Android MainActivity.checkClipboardUrl)
    private func checkClipboardForGalleryUrl() {
        guard flowStep == .main else { return }

        #if os(iOS)
        // iOS 16+: 先用 detectPatterns 检测是否包含 URL，避免触发粘贴板隐私弹窗
        if #available(iOS 16.0, *) {
            Task {
                do {
                    let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [\.probableWebURL]
                    let results = try await UIPasteboard.general.detectedPatterns(for: patterns)
                    guard results.contains(\.probableWebURL) else { return }
                    // 剪贴板确实包含 URL，再读取内容 (此时系统不会再弹隐私提示)
                    await MainActor.run {
                        readClipboardContent()
                    }
                } catch {
                    // 检测失败则不读取
                }
            }
        } else {
            readClipboardContent()
        }
        #else
        readClipboardContent()
        #endif
    }

    /// 读取剪贴板内容并匹配画廊链接
    private func readClipboardContent() {
        #if os(iOS)
        guard let content = UIPasteboard.general.string else { return }
        #else
        guard let content = NSPasteboard.general.string(forType: .string) else { return }
        #endif

        // 避免重复检测同一内容
        guard content != lastClipboardContent else { return }
        lastClipboardContent = content

        // 匹配 EH 画廊 URL: https://e-hentai.org/g/GID/TOKEN/
        let pattern = #"https?://(e-hentai|exhentai)\.org/g/(\d+)/([0-9a-f]{10})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              match.numberOfRanges >= 4,
              let gidRange = Range(match.range(at: 2), in: content),
              let tokenRange = Range(match.range(at: 3), in: content),
              let gid = Int64(content[gidRange]) else { return }

        let token = String(content[tokenRange])
        clipboardGallery = (gid: gid, token: token)
        showClipboardAlert = true
    }
}

// MARK: - 全局应用状态

@MainActor
@Observable
final class AppState {
    var isSignedIn = false
    var currentSite: SiteChoice = .eHentai

    enum SiteChoice: Int {
        case eHentai = 0
        case exHentai = 1
    }

    func checkLoginStatus() {
        // 检查 Cookie 是否存在
        let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://e-hentai.org")!) ?? []
        let hasMemberId = cookies.contains { $0.name == "ipb_member_id" }
        let hasPassHash = cookies.contains { $0.name == "ipb_pass_hash" }
        isSignedIn = hasMemberId && hasPassHash

        // Fix F1-3: 未登录或无有效 igneous Cookie 时，强制降级到 E-Hentai
        if !isSignedIn && AppSettings.shared.gallerySite == .exHentai {
            AppSettings.shared.gallerySite = .eHentai
        } else if isSignedIn && AppSettings.shared.gallerySite == .exHentai {
            validateExHentaiAccess()
        }
    }

    /// 检查 ExHentai 访问权限 (igneous cookie)
    /// 无有效 igneous 时自动降级到 E-Hentai 并提示
    private func validateExHentaiAccess() {
        let exCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
        let hasIgneous = exCookies.contains { $0.name == "igneous" && !$0.value.isEmpty && $0.value != "mystery" }
        if !hasIgneous {
            AppSettings.shared.gallerySite = .eHentai
        }
    }

    func signOut() {
        // 清除所有 EH 相关 Cookie
        let domains = ["e-hentai.org", "exhentai.org", "forums.e-hentai.org"]
        for domain in domains {
            if let url = URL(string: "https://\(domain)") {
                let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
                for cookie in cookies {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
            }
        }
        isSignedIn = false
    }
}

#Preview {
    RootView()
}
