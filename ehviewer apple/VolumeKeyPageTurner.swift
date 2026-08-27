//
//  VolumeKeyPageTurner.swift
//  ehviewer apple
//
//  音量键 / 外置翻页器翻页 — 对齐 Android GalleryActivity 的 `volume_page` 设置
//
//  背景 (issue #4「无法使用外置翻页器翻页」):
//  蓝牙翻页器有两类工作模式 —
//    1. 键盘模式: 发送 ←/→ ↑/↓ PageUp/PageDown Space/Enter → 由 ImageReaderView 的
//       `.onKeyPress` 处理 (需要视图处于 focus 状态, 见 ImageReaderView.focusable)
//    2. 媒体模式: 发送音量加/减 → 由本文件处理
//
//  实现方式: KVO 监听 AVAudioSession.outputVolume, 触发翻页后把系统音量复位到基准值,
//  这样用户可以连续按。视图层内嵌一个离屏 MPVolumeView, 同时用于复位音量和抑制系统音量 HUD。
//

#if os(iOS)

import AVFoundation
import MediaPlayer
import UIKit
import EhSettings

@MainActor
final class VolumeKeyPageTurner {

    /// 复位基准音量 — 保持在中间位置，上下都有余量
    private static let baseVolume: Float = 0.5
    /// 小于该幅度的变化视为复位回声，忽略
    private static let threshold: Float = 0.005

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var isResetting = false
    private var onNext: () -> Void = {}
    private var onPrevious: () -> Void = {}

    var isRunning: Bool { observation != nil }

    // MARK: - 生命周期

    /// 开始监听
    /// - Parameters:
    ///   - onNext: 下一页回调
    ///   - onPrevious: 上一页回调
    func start(onNext: @escaping () -> Void, onPrevious: @escaping () -> Void) {
        guard observation == nil else { return }
        self.onNext = onNext
        self.onPrevious = onPrevious

        let session = AVAudioSession.sharedInstance()
        // .ambient + .mixWithOthers: 不打断用户正在播放的音乐/播客
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        attachVolumeView()
        resetVolume(animated: false)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.handleVolumeChange(newValue)
            }
        }
    }

    /// 停止监听并还原
    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    deinit {
        observation?.invalidate()
    }

    // MARK: - 内部实现

    private func handleVolumeChange(_ newVolume: Float) {
        // 忽略自己复位音量引起的回调
        guard !isResetting else { return }

        let delta = newVolume - Self.baseVolume
        guard abs(delta) > Self.threshold else { return }

        let reverse = AppSettings.shared.reverseVolumePage
        // 默认: 音量+ = 上一页, 音量- = 下一页 (对齐 Android VOLUME_PAGE 默认方向)
        let goForward = reverse ? (delta > 0) : (delta < 0)
        if goForward { onNext() } else { onPrevious() }

        resetVolume(animated: false)
    }

    /// 把系统音量复位到基准值，使用户可以连续按同一个键
    private func resetVolume(animated: Bool) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        isResetting = true
        slider.setValue(Self.baseVolume, animated: animated)
        slider.sendActions(for: .valueChanged)
        // 复位是异步生效的，稍后再放开事件处理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isResetting = false
        }
    }

    /// 把离屏 MPVolumeView 挂到当前窗口上
    /// (MPVolumeView 必须在视图层级里 slider 才存在；同时它会抑制系统音量 HUD)
    private func attachVolumeView() {
        guard volumeView == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return }

        let view = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        view.showsRouteButton = false
        window.addSubview(view)
        volumeView = view
    }
}

#endif
