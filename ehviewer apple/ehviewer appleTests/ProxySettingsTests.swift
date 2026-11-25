import Testing
import Foundation
import EhSettings

// MARK: - 设置项之间不能串键

/// 两个设置共用一个 UserDefaults 键，表现是「开 A 顺带开了 B」。
///
/// 这不是假想：新加的「切到后台时隐藏内容」(enableSecureScreen) 一开始沿用了
/// Android 的键名 `enable_secure`，而本项目里那个键早就被应用锁
/// (enableSecurity) 占着了——打开隐私遮罩会连应用锁一起打开，模拟器上直接
/// 被锁在验证界面外面。这里针对那对具体的设置守住。
@Suite(.serialized)
@MainActor
struct SettingsKeyIsolationTests {

    @Test func secureScreenDoesNotToggleAppLock() {
        let settings = AppSettings.shared
        let originalLock = settings.enableSecurity
        let originalScreen = settings.enableSecureScreen
        defer {
            settings.enableSecurity = originalLock
            settings.enableSecureScreen = originalScreen
        }

        settings.enableSecurity = false
        settings.enableSecureScreen = true
        #expect(!settings.enableSecurity, "开隐私遮罩把应用锁也打开了 —— 两者共用了同一个键")

        settings.enableSecureScreen = false
        settings.enableSecurity = true
        #expect(!settings.enableSecureScreen, "开应用锁把隐私遮罩也打开了")
    }
}
