//
//  SecurityView.swift
//  ehviewer apple
//
//  安全锁屏视图 (对应 Android SecurityScene)
//  支持 Face ID / Touch ID / 设备密码解锁
//  Fix F1-1: 无生物识别时自动降级到设备密码; 设备无密码时自动跳过
//  Fix F1-2: 生物识别锁定后显示"使用密码"按钮; 重试锁定 60 秒后自动恢复
//

import SwiftUI
import LocalAuthentication
import EhSettings

/// 安全锁屏视图
/// 应用启动时如果启用了安全功能，需要先通过认证
struct SecurityView: View {
    let onAuthenticated: () -> Void
    
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var retryCount = 0
    /// 是否已被锁定 (生物识别 lockout 或重试次数过多)
    @State private var isLockedOut = false
    /// 锁定倒计时秒数
    @State private var lockoutRemaining = 0
    @State private var lockoutTimer: Timer?
    /// 设备是否完全不支持任何认证 (无生物识别+无密码)
    @State private var deviceHasNoAuth = false
    
    private let maxRetries = 5
    private let lockoutDuration = 60 // 锁定 60 秒后自动恢复
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // 锁图标
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
            
            Text("EhViewer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("请验证身份以继续")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            // 生物识别图标
            if !deviceHasNoAuth {
                biometricIcon
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                    .padding(.top, 24)
            }
            
            if let error = authError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            if deviceHasNoAuth {
                // Fix F1-1: 设备完全不支持任何认证 → 自动禁用安全功能并放行
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("此设备未设置锁屏密码或生物识别")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("安全锁定已自动关闭")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("进入应用") {
                        // 自动禁用安全功能，防止下次再卡死
                        AppSettings.shared.enableSecurity = false
                        onAuthenticated()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 32)
            } else {
                // 主解锁按钮: 优先使用生物识别
                if hasBiometrics {
                    Button(action: authenticateWithBiometrics) {
                        HStack {
                            Image(systemName: biometricSystemImage)
                            Text("使用 \(biometricName) 解锁")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating || isLockedOut)
                    .padding(.horizontal, 32)
                }
                
                // Fix F1-2: 始终显示"使用密码解锁"按钮 — 生物识别锁定/失败时的保底路径
                Button(action: authenticateWithPasscode) {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text("使用设备密码解锁")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(isAuthenticating)
                .padding(.horizontal, 32)
                
                // 锁定倒计时
                if isLockedOut && lockoutRemaining > 0 {
                    Text("生物识别已暂时锁定，\(lockoutRemaining) 秒后可重试")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
                
                // 重试计数 (仅生物识别, 密码不限)
                if retryCount > 0 && retryCount < maxRetries && !isLockedOut {
                    Text("生物识别剩余尝试: \(maxRetries - retryCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            checkDeviceCapabilities()
            // 自动触发认证
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !deviceHasNoAuth {
                    if hasBiometrics {
                        authenticateWithBiometrics()
                    } else {
                        authenticateWithPasscode()
                    }
                }
            }
        }
        .onDisappear {
            lockoutTimer?.invalidate()
            lockoutTimer = nil
        }
    }
    
    // MARK: - 设备能力检测
    
    /// 检测设备是否支持任何认证方式
    private func checkDeviceCapabilities() {
        let context = LAContext()
        var error: NSError?
        let hasBio = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let hasPasscode = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        
        if !hasBio && !hasPasscode {
            // Fix F1-1: 设备完全无认证能力 → 标记后自动放行
            deviceHasNoAuth = true
        }
    }
    
    // MARK: - 生物识别类型
    
    private var hasBiometrics: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
    
    private var biometricType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }
    
    private var biometricName: String {
        switch biometricType {
        case .none:
            return "密码"
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        @unknown default:
            return "生物识别"
        }
    }
    
    private var biometricSystemImage: String {
        switch biometricType {
        case .none:
            return "lock.shield"
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        @unknown default:
            return "lock.shield"
        }
    }
    
    @ViewBuilder
    private var biometricIcon: some View {
        switch biometricType {
        case .none:
            Image(systemName: "lock.shield")
        case .faceID:
            Image(systemName: "faceid")
        case .touchID:
            Image(systemName: "touchid")
        case .opticID:
            Image(systemName: "opticid")
        @unknown default:
            Image(systemName: "lock.shield")
        }
    }
    
    // MARK: - 认证 (生物识别)
    
    private func authenticateWithBiometrics() {
        guard !isAuthenticating else { return }
        guard !isLockedOut else { return }
        guard retryCount < maxRetries else {
            startLockout()
            return
        }
        
        isAuthenticating = true
        authError = nil
        
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        // 不显示系统的 "输入密码" 回退按钮, 由我们自己的按钮处理
        context.localizedFallbackTitle = ""
        
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "验证身份以访问 EhViewer"
        ) { success, authenticationError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    onAuthenticated()
                } else {
                    handleBiometricError(authenticationError)
                }
            }
        }
    }
    
    // MARK: - 认证 (设备密码 — Fallback)
    
    /// 使用 deviceOwnerAuthentication 策略弹出系统密码输入界面
    private func authenticateWithPasscode() {
        guard !isAuthenticating else { return }
        
        isAuthenticating = true
        authError = nil
        
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "验证身份以访问 EhViewer"
        ) { success, authenticationError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    // 密码认证成功 — 同时重置生物识别锁定状态
                    retryCount = 0
                    isLockedOut = false
                    lockoutTimer?.invalidate()
                    lockoutTimer = nil
                    onAuthenticated()
                } else {
                    if let laError = authenticationError as? LAError, laError.code == .userCancel {
                        authError = "认证已取消"
                    } else {
                        authError = authenticationError?.localizedDescription ?? "密码认证失败"
                    }
                }
            }
        }
    }
    
    // MARK: - 错误处理
    
    private func handleBiometricError(_ error: Error?) {
        retryCount += 1
        
        guard let laError = error as? LAError else {
            authError = error?.localizedDescription
            return
        }
        
        switch laError.code {
        case .userCancel:
            // 用户取消不算重试
            retryCount -= 1
            authError = "认证已取消，请点击按钮重试"
        case .userFallback:
            // 用户选择使用密码
            retryCount -= 1
            authenticateWithPasscode()
        case .biometryNotAvailable:
            authError = "生物识别不可用，请使用密码解锁"
        case .biometryNotEnrolled:
            authError = "未设置生物识别，请使用密码解锁"
        case .biometryLockout:
            // Fix F1-2: 生物识别被系统锁定 — 引导使用密码
            authError = "生物识别已锁定，请使用下方密码解锁"
            startLockout()
        case .authenticationFailed:
            if retryCount >= maxRetries {
                startLockout()
            } else {
                authError = "认证失败，请重试"
            }
        default:
            authError = laError.localizedDescription
        }
    }
    
    // MARK: - 锁定管理
    
    /// Fix F1-2: 启动锁定倒计时, 60 秒后自动恢复
    private func startLockout() {
        isLockedOut = true
        lockoutRemaining = lockoutDuration
        authError = "生物识别重试次数过多，请使用密码解锁或等待 \(lockoutDuration) 秒"
        
        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                lockoutRemaining -= 1
                if lockoutRemaining <= 0 {
                    isLockedOut = false
                    retryCount = 0
                    authError = nil
                    lockoutTimer?.invalidate()
                    lockoutTimer = nil
                }
            }
        }
    }
}

#Preview {
    SecurityView(onAuthenticated: { print("Authenticated") })
}
