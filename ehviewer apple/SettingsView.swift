//
//  SettingsView.swift
//  ehviewer apple
//
//  设置视图
//

import SwiftUI
import EhSettings
import EhDownload
import EhDatabase
import EhSpider
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @State private var vm = SettingsViewModel()
    @Environment(\.openURL) private var openURL

    /// 被推入父导航栈时，不创建自己的 NavigationStack，避免嵌套
    private var isPushed: Bool = false

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    var body: some View {
        if isPushed {
            settingsInnerContent
        } else {
            NavigationStack {
                settingsInnerContent
            }
        }
    }

    private var settingsInnerContent: some View {
        Form {
            accountSection
            siteSection
            #if DEBUG
            filterSection
            #endif
            displaySection
            favoritesSection
            networkSection
            readingSection
            downloadSection
            cacheSection
            securitySection
            advancedSection
            aboutSection
        }
        .navigationTitle("设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("账号") {
            if vm.isLoggedIn {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = vm.displayName, !name.isEmpty {
                            Text(name)
                                .font(.subheadline.bold())
                        } else {
                            Text("已登录")
                                .font(.subheadline.bold())
                        }
                        HStack(spacing: 8) {
                            if let uid = vm.userId, !uid.isEmpty {
                                Text("UID: \(uid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(vm.hasExAccess ? "ExHentai 可用" : "仅 E-Hentai (未登录)")
                                .font(.caption)
                                .foregroundStyle(vm.hasExAccess ? Color.green : .secondary)
                        }
                    }
                }

                // 身份 Cookies (对齐 Android: identity_cookie)
                NavigationLink("身份 Cookies") {
                    identityCookiesView
                }

                Button("注销", role: .destructive) {
                    vm.showLogoutConfirm = true
                }
            } else {
                Button("登录") {
                    vm.showLogin = true
                }
            }
        }
        .confirmationDialog("确认注销？", isPresented: $vm.showLogoutConfirm, titleVisibility: .visible) {
            Button("注销", role: .destructive) {
                vm.logout()
            }
        }
        .sheet(isPresented: $vm.showLogin) {
            LoginView()
        }
    }

    // MARK: - Site

    private var siteSection: some View {
        Section("站点") {
            Picker("默认站点", selection: $vm.gallerySite) {
                Text("E-Hentai").tag(0)
                Text("ExHentai").tag(1)
            }

            // EH 站点设置 (对齐 Android: u_config)
            Button {
                let site = AppSettings.shared.gallerySite
                let url = site == .exHentai
                    ? "https://exhentai.org/uconfig.php"
                    : "https://e-hentai.org/uconfig.php"
                openURL(URL(string: url)!)
            } label: {
                HStack {
                    Text("EH 站点设置")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 我的标签 (对齐 Android: my_tags)
            Button {
                let site = AppSettings.shared.gallerySite
                let url = site == .exHentai
                    ? "https://exhentai.org/mytags"
                    : "https://e-hentai.org/mytags"
                openURL(URL(string: url)!)
            } label: {
                HStack {
                    Text("我的标签")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("列表模式", selection: $vm.listMode) {
                Text("列表").tag(0)
                Text("紧凑").tag(1)
                Text("网格").tag(2)
            }

            // TODO: Connect to Logic — detailSize 未被 GalleryDetailView 读取
            #if DEBUG
            Picker("详情页大小", selection: Binding(
                get: { AppSettings.shared.detailSize },
                set: { AppSettings.shared.detailSize = $0 }
            )) {
                Text("常规").tag(0)
                Text("大号").tag(1)
            }
            #endif

            Toggle("显示日文标题", isOn: $vm.showJpnTitle)

            // 标签翻译设置
            Toggle("显示标签翻译", isOn: $vm.showTagTranslations)
            
            if vm.showTagTranslations {
                HStack {
                    Text("标签数据库")
                    Spacer()
                    if vm.isUpdatingTagDb {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text(vm.tagDbStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button {
                    Task { await vm.updateTagDatabase() }
                } label: {
                    HStack {
                        Text("更新标签翻译数据库")
                        Spacer()
                        if vm.tagDbUpdateSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .disabled(vm.isUpdatingTagDb)

                // 标签翻译来源标注 (对齐 Android: tag_translations_source)
                Button {
                    openURL(URL(string: "https://github.com/EhTagTranslation")!)
                } label: {
                    HStack {
                        Text("补充翻译（由 EhTagTranslator 提供）")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink("标签过滤") {
                FilterView()
            }

            // 屏蔽列表 (对齐 Android: BlackListActivity)
            NavigationLink("屏蔽列表") {
                FilterView()
            }

            // TODO: Connect to Logic — cellularNetworkWarning 未被网络层检查
            #if DEBUG
            Toggle("移动网络提醒", isOn: Binding(
                get: { AppSettings.shared.cellularNetworkWarning },
                set: { AppSettings.shared.cellularNetworkWarning = $0 }
            ))
            #endif
        }
    }

    // MARK: - Filter / Search (对齐 Android: 默认分类/排除标签命名空间/排除语言)
    // TODO: Connect to Logic — defaultCategories/excludedTagNamespaces/excludedLanguages 未作为 URL 参数发送
    #if DEBUG
    private var filterSection: some View {
        Section("搜索过滤") {
            NavigationLink("默认搜索分类") {
                defaultCategoriesView
            }

            NavigationLink("排除的标签命名空间") {
                excludedNamespacesView
            }

            NavigationLink("排除的语言") {
                excludedLanguagesView
            }
        }
    }
    #endif

    // MARK: - Network

    private var networkSection: some View {
        Section("网络") {
            Toggle("域名前置", isOn: $vm.domainFronting)

            Toggle("DNS over HTTPS", isOn: $vm.dnsOverHttps)

            Toggle("内置 Hosts", isOn: $vm.builtInHosts)

            // TODO: Connect to Logic — builtExHosts 未被 EhDNS 读取
            #if DEBUG
            Toggle("内置 ExH Hosts", isOn: Binding(
                get: { AppSettings.shared.builtExHosts },
                set: { AppSettings.shared.builtExHosts = $0 }
            ))
            #endif
            
            // 网络诊断按钮
            Button {
                vm.runNetworkDiagnostics()
            } label: {
                HStack {
                    Text("网络诊断")
                    Spacer()
                    if vm.isDiagnosing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if !vm.diagnosisResult.isEmpty {
                        Image(systemName: vm.diagnosisSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(vm.diagnosisSuccess ? .green : .orange)
                    }
                }
            }
            .disabled(vm.isDiagnosing)
            
            if !vm.diagnosisResult.isEmpty {
                Text(vm.diagnosisResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Display (对齐 Android Settings: 外观)

    private var displaySection: some View {
        Section("外观") {
            // 深色模式 (对齐 Android Settings.KEY_THEME)
            Picker("主题", selection: Binding(
                get: { AppSettings.shared.theme },
                set: { AppSettings.shared.theme = $0 }
            )) {
                Text("跟随系统").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            }

            // 启动页面 (对齐 Android Settings.KEY_LAUNCH_PAGE)
            Picker("启动页面", selection: Binding(
                get: { AppSettings.shared.launchPage },
                set: { AppSettings.shared.launchPage = $0 }
            )) {
                Text("首页").tag(0)
                Text("热门").tag(1)
                Text("排行榜").tag(2)
                Text("收藏").tag(3)
                Text("下载").tag(4)
                Text("历史").tag(5)
            }

            // TODO: Connect to Logic — showGalleryPages 未被列表视图读取
            #if DEBUG
            Toggle("显示画廊页数", isOn: Binding(
                get: { AppSettings.shared.showGalleryPages },
                set: { AppSettings.shared.showGalleryPages = $0 }
            ))
            #endif

            Toggle("显示评论区", isOn: Binding(
                get: { AppSettings.shared.showGalleryComment },
                set: { AppSettings.shared.showGalleryComment = $0 }
            ))

            // TODO: Connect to Logic — showGalleryRating 未被详情页读取(评分始终显示)
            #if DEBUG
            Toggle("显示评分", isOn: Binding(
                get: { AppSettings.shared.showGalleryRating },
                set: { AppSettings.shared.showGalleryRating = $0 }
            ))
            #endif

            // TODO: Connect to Logic — showReadProgress 未被列表视图读取
            #if DEBUG
            Toggle("显示阅读进度", isOn: Binding(
                get: { AppSettings.shared.showReadProgress },
                set: { AppSettings.shared.showReadProgress = $0 }
            ))
            #endif

            // TODO: Connect to Logic — thumbSize 未被列表/图片视图读取
            #if DEBUG
            Picker("缩略图大小", selection: Binding(
                get: { AppSettings.shared.thumbSize },
                set: { AppSettings.shared.thumbSize = $0 }
            )) {
                Text("小").tag(0)
                Text("中").tag(1)
                Text("大").tag(2)
            }
            #endif

            // TODO: Connect to Logic — thumbResolution 未被任何代码读取
            #if DEBUG
            Picker("缩略图分辨率", selection: Binding(
                get: { AppSettings.shared.thumbResolution },
                set: { AppSettings.shared.thumbResolution = $0 }
            )) {
                Text("普通").tag(0)
                Text("高清").tag(1)
            }
            #endif

            // TODO: Connect to Logic — fixThumbUrl 未被图片加载代码读取
            #if DEBUG
            Toggle("修复缩略图链接", isOn: Binding(
                get: { AppSettings.shared.fixThumbUrl },
                set: { AppSettings.shared.fixThumbUrl = $0 }
            ))
            #endif

            // 大屏幕列表布局 (对齐 Android: 全宽单列表布局选项)
            Picker("宽屏布局", selection: Binding(
                get: { AppSettings.shared.wideScreenListMode },
                set: { AppSettings.shared.wideScreenListMode = $0 }
            )) {
                Text("双栏 (列表+详情)").tag(0)
                Text("全宽单列表").tag(1)
            }
        }
    }

    // MARK: - Favorites (对齐 Android Settings: 收藏)

    private var favoritesSection: some View {
        Section("收藏") {
            // 默认收藏夹 (对齐 Android Settings.KEY_DEFAULT_FAV_SLOT)
            Picker("默认收藏夹", selection: Binding(
                get: { AppSettings.shared.defaultFavSlot },
                set: { AppSettings.shared.defaultFavSlot = $0 }
            )) {
                Text("每次询问").tag(-2)
                ForEach(0..<10) { slot in
                    Text(AppSettings.shared.favCatName(slot)).tag(slot)
                }
            }

            NavigationLink("收藏夹名称") {
                favCatNamesView
            }
        }
    }

    private var favCatNamesView: some View {
        List {
            ForEach(0..<10, id: \.self) { slot in
                HStack {
                    Text("收藏夹 \(slot)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("名称", text: Binding(
                        get: { AppSettings.shared.favCatName(slot) },
                        set: { AppSettings.shared.setFavCatName(slot, $0) }
                    ))
                    .multilineTextAlignment(.trailing)
                }
            }
        }
        .navigationTitle("收藏夹名称")
    }

    // MARK: - Reading

    private var readingSection: some View {
        Section("阅读") {
            // 阅读方向 (对齐 Android Settings.KEY_READING_DIRECTION)
            Picker("阅读方向", selection: Binding(
                get: { AppSettings.shared.readingDirection },
                set: { AppSettings.shared.readingDirection = $0 }
            )) {
                Text("左→右").tag(0)
                Text("右→左").tag(1)
                Text("上→下").tag(2)
                Text("滚动模式").tag(3)
            }

            // 页面缩放 (对齐 Android Settings.KEY_PAGE_SCALING)
            Picker("页面缩放", selection: Binding(
                get: { AppSettings.shared.pageScaling },
                set: { AppSettings.shared.pageScaling = $0 }
            )) {
                Text("适合屏幕").tag(0)
                Text("适合宽度").tag(1)
                Text("适合高度").tag(2)
                Text("原始大小").tag(3)
                Text("等比缩放").tag(4)
            }

            // 起始位置 (对齐 Android Settings.KEY_START_POSITION)
            Picker("起始位置", selection: Binding(
                get: { AppSettings.shared.startPosition },
                set: { AppSettings.shared.startPosition = $0 }
            )) {
                Text("默认").tag(0)
                Text("顶部").tag(1)
                Text("右上").tag(2)
                Text("底部").tag(3)
                Text("右下").tag(4)
                Text("居中").tag(5)
            }

            // 屏幕旋转 (对齐 Android Settings.KEY_SCREEN_ROTATION)
            Picker("屏幕旋转", selection: Binding(
                get: { AppSettings.shared.screenRotation },
                set: { newValue in
                    AppSettings.shared.screenRotation = newValue
                    // 立即应用旋转设置
                    #if os(iOS)
                    applyScreenRotation(newValue)
                    #endif
                }
            )) {
                Text("跟随系统").tag(0)
                Text("竖屏锁定").tag(1)
                Text("横屏锁定").tag(2)
            }

            Stepper("预加载页数: \(vm.preloadImage)", value: $vm.preloadImage, in: 1...10)

            Toggle("保持屏幕常亮", isOn: $vm.keepScreenOn)

            Toggle("全屏阅读", isOn: Binding(
                get: { AppSettings.shared.readingFullscreen },
                set: { AppSettings.shared.readingFullscreen = $0 }
            ))

            Toggle("显示时钟", isOn: Binding(
                get: { AppSettings.shared.showClock },
                set: { AppSettings.shared.showClock = $0 }
            ))

            Toggle("显示进度", isOn: Binding(
                get: { AppSettings.shared.showProgress },
                set: { AppSettings.shared.showProgress = $0 }
            ))

            Toggle("显示电量", isOn: Binding(
                get: { AppSettings.shared.showBattery },
                set: { AppSettings.shared.showBattery = $0 }
            ))

            Toggle("显示页间距", isOn: Binding(
                get: { AppSettings.shared.showPageInterval },
                set: { AppSettings.shared.showPageInterval = $0 }
            ))

            // TODO: Connect to Logic — volumePage/reverseVolumePage 未被 ImageReaderView 读取
            #if DEBUG && os(iOS)
            Toggle("音量键翻页", isOn: Binding(
                get: { AppSettings.shared.volumePage },
                set: { AppSettings.shared.volumePage = $0 }
            ))

            if AppSettings.shared.volumePage {
                Toggle("反转音量键方向", isOn: Binding(
                    get: { AppSettings.shared.reverseVolumePage },
                    set: { AppSettings.shared.reverseVolumePage = $0 }
                ))
            }
            #endif

            // 自定义亮度 (对齐 Android Settings.KEY_CUSTOM_SCREEN_LIGHTNESS)
            Toggle("自定义亮度", isOn: Binding(
                get: { AppSettings.shared.customScreenLightness },
                set: { AppSettings.shared.customScreenLightness = $0 }
            ))

            if AppSettings.shared.customScreenLightness {
                Slider(value: Binding(
                    get: { Double(AppSettings.shared.screenLightness) },
                    set: { AppSettings.shared.screenLightness = Int($0) }
                ), in: 0...100, step: 1) {
                    Text("亮度: \(AppSettings.shared.screenLightness)%")
                }
            }

            // 自动翻页间隔 (对齐 Android Settings.KEY_AUTO_PAGE_INTERVAL)
            Stepper("自动翻页间隔: \(vm.autoPageInterval)s", value: $vm.autoPageInterval, in: 1...60)

            // TODO: Connect to Logic — colorFilter/colorFilterColor 未被 ImageReaderView 读取
            #if DEBUG
            Toggle("色彩滤镜 (护眼)", isOn: Binding(
                get: { AppSettings.shared.colorFilter },
                set: { AppSettings.shared.colorFilter = $0 }
            ))
            #endif
        }
    }

    // MARK: - Download

    private var downloadSection: some View {
        Section("下载") {
            #if os(macOS)
            // macOS: 自定义下载路径
            HStack {
                Text("下载位置")
                Spacer()
                Text(vm.downloadPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("更改...") {
                    vm.chooseDownloadPath()
                }
                .buttonStyle(.link)
            }
            #endif

            Stepper("并发线程: \(vm.multiThread)", value: $vm.multiThread, in: 1...5)

            Stepper("超时 (秒): \(vm.downloadTimeout)", value: $vm.downloadTimeout, in: 10...120, step: 10)

            // 下载延迟 (对齐 Android Settings.KEY_DOWNLOAD_DELAY)
            Stepper("下载延迟: \(vm.downloadDelay) ms", value: $vm.downloadDelay, in: 0...2000, step: 100)

            // TODO: Connect to Logic — imageResolution 未作为请求参数发送
            #if DEBUG
            Picker("图片分辨率", selection: Binding(
                get: { AppSettings.shared.imageResolution },
                set: { AppSettings.shared.imageResolution = $0 }
            )) {
                ForEach(ImageResolution.allCases) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
            #endif

            // 下载原图 (对齐 Android Settings.KEY_DOWNLOAD_ORIGIN_IMAGE)
            Toggle("下载原始图片", isOn: Binding(
                get: { AppSettings.shared.downloadOriginImage },
                set: { AppSettings.shared.downloadOriginImage = $0 }
            ))

            // TODO: Connect to Logic — mediaScan 是 Android 概念，iOS 无意义
            #if DEBUG
            Toggle("媒体扫描", isOn: Binding(
                get: { AppSettings.shared.mediaScan },
                set: { AppSettings.shared.mediaScan = $0 }
            ))
            #endif

            // 恢复下载项目 (对齐 Android: restore_download_items)
            Button {
                vm.restoreDownloadItems()
            } label: {
                HStack {
                    Text("恢复下载项目")
                    Spacer()
                    if vm.isRestoring {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .disabled(vm.isRestoring)

            if let msg = vm.restoreResultMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 清除冗余数据 (对齐 Android: clean_redundancy)
            Button {
                vm.cleanRedundancy()
            } label: {
                HStack {
                    Text("清除下载冗余数据")
                    Spacer()
                    if vm.isCleaning {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .disabled(vm.isCleaning)
            .confirmationDialog(
                "发现 \(vm.cleanOrphanCount) 个冗余目录 (\(vm.cleanOrphanSize))，确认删除？",
                isPresented: $vm.showCleanConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    vm.confirmCleanRedundancy()
                }
                Button("取消", role: .cancel) {
                    vm.cancelClean()
                }
            }

            if let msg = vm.cleanResultMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section("缓存") {
            // 阅读缓存大小 (对齐 Android Settings.KEY_READ_CACHE_SIZE)
            Picker("阅读缓存大小", selection: Binding(
                get: { AppSettings.shared.readCacheSize },
                set: { AppSettings.shared.readCacheSize = $0 }
            )) {
                Text("40 MB").tag(40)
                Text("80 MB").tag(80)
                Text("120 MB").tag(120)
                Text("160 MB").tag(160)
                Text("240 MB").tag(240)
                Text("320 MB").tag(320)
                Text("480 MB").tag(480)
                Text("640 MB").tag(640)
            }

            HStack {
                Text("磁盘缓存")
                Spacer()
                Text(vm.diskCacheSize)
                    .foregroundStyle(.secondary)
            }

            // 清除内存缓存 (对齐 Android: clear_memory_cache)
            Button("清除内存缓存") {
                vm.clearMemoryCache()
            }

            Button("清除磁盘缓存") {
                vm.clearCache()
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section("隐私与安全") {
            Toggle("启用应用锁", isOn: Binding(
                get: { AppSettings.shared.enableSecurity },
                set: { AppSettings.shared.enableSecurity = $0 }
            ))

            if AppSettings.shared.enableSecurity {
                Picker("解锁延迟", selection: Binding(
                    get: { AppSettings.shared.securityDelay },
                    set: { AppSettings.shared.securityDelay = $0 }
                )) {
                    Text("立即").tag(0)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("15 分钟").tag(900)
                }
            }
        }
    }

    // MARK: - Advanced (对齐 Android Settings: 高级)

    private var advancedSection: some View {
        Section("高级") {
            // 历史记录容量 (对齐 Android Settings.KEY_HISTORY_INFO_SIZE)
            Stepper("历史记录上限: \(vm.historyInfoSize)", value: $vm.historyInfoSize, in: 100...2000, step: 100)

            // TODO: Connect to Logic — saveParseErrorBody 未被解析器读取
            #if DEBUG
            Toggle("保存解析错误", isOn: Binding(
                get: { AppSettings.shared.saveParseErrorBody },
                set: { AppSettings.shared.saveParseErrorBody = $0 }
            ))
            #endif

            // 导出数据 (对齐 Android: export_data)
            Button("导出数据") {
                vm.exportData()
            }

            // 导入数据 (对齐 Android: import_data)
            Button("导入数据") {
                vm.importData()
            }
            .fileImporter(
                isPresented: $vm.showImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                vm.handleImport(result)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }

            Button("源代码") {
                openURL(URL(string: "https://github.com/felixchaos/EhViewer-Apple")!)
            }

            NavigationLink("开源协议") {
                licensesView
            }
        }
    }

    private var licensesView: some View {
        List {
            // 本项目
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("EhViewer-Apple")
                            .font(.headline)
                        Spacer()
                        Text("Apache-2.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Copyright © 2024 felixchaos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("""
Licensed under the Apache License, Version 2.0 (the "License"); \
you may not use this file except in compliance with the License. \
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software \
distributed under the License is distributed on an "AS IS" BASIS, \
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. \
See the License for the specific language governing permissions and \
limitations under the License.
""")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("本项目")
            }

            // 致谢
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EhViewer")
                        .font(.subheadline.bold())
                    Text("原始 Android EhViewer 项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("EhViewer_CN_SXJ")
                        .font(.subheadline.bold())
                    Text("EhViewer 中文分支，本项目参考了其 UI 设计与功能逻辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("致谢")
            }

            // 第三方库
            Section {
                ForEach(licensedLibraries, id: \.name) { lib in
                    DisclosureGroup {
                        Text(lib.licenseText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text(lib.name)
                                .font(.subheadline)
                            Spacer()
                            Text(lib.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("第三方开源库")
            }
        }
        .navigationTitle("开源协议")
    }

    private struct LicensedLibrary {
        let name: String
        let license: String
        let licenseText: String
    }

    private var licensedLibraries: [LicensedLibrary] {
        [
            LicensedLibrary(
                name: "GRDB.swift",
                license: "MIT",
                licenseText: """
Copyright (C) 2015-2024 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
            ),
            LicensedLibrary(
                name: "SwiftSoup",
                license: "MIT",
                licenseText: """
Copyright (c) 2016 Nabil Chatbi

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
            ),
            LicensedLibrary(
                name: "SDWebImageSwiftUI",
                license: "MIT",
                licenseText: """
Copyright (c) 2019 lizhuoli1126@126.com

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
            ),
        ]
    }

    // MARK: - Screen Rotation Helper

    #if os(iOS)
    /// 立即应用屏幕旋转设置 (对齐 Android setRequestedOrientation)
    private func applyScreenRotation(_ mode: Int) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }

        let orientations: UIInterfaceOrientationMask
        switch mode {
        case 1:
            orientations = .portrait
        case 2:
            orientations = .landscape
        default:
            orientations = .allButUpsideDown
        }

        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
        windowScene.requestGeometryUpdate(geometryPreferences) { error in
            print("[SettingsView] 旋转更新错误: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - Identity Cookies View (对齐 Android: IdentityCookiePreference)

    private var identityCookiesView: some View {
        List {
            let ehCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://e-hentai.org")!) ?? []
            let exCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []

            Section("E-Hentai Cookies") {
                ForEach(ehCookies, id: \.name) { cookie in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cookie.name)
                            .font(.subheadline.bold())
                        Text(cookie.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contextMenu {
                        Button("复制") {
                            #if os(iOS)
                            UIPasteboard.general.string = "\(cookie.name)=\(cookie.value)"
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(cookie.name)=\(cookie.value)", forType: .string)
                            #endif
                        }
                    }
                }
                if ehCookies.isEmpty {
                    Text("无 Cookie")
                        .foregroundStyle(.secondary)
                }
            }

            Section("ExHentai Cookies") {
                ForEach(exCookies, id: \.name) { cookie in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cookie.name)
                            .font(.subheadline.bold())
                        Text(cookie.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contextMenu {
                        Button("复制") {
                            #if os(iOS)
                            UIPasteboard.general.string = "\(cookie.name)=\(cookie.value)"
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(cookie.name)=\(cookie.value)", forType: .string)
                            #endif
                        }
                    }
                }
                if exCookies.isEmpty {
                    Text("无 Cookie")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("身份 Cookies")
    }

    // MARK: - Default Categories View (对齐 Android: DefaultCategoryActivity)

    private var defaultCategoriesView: some View {
        let allCategories: [(String, Int)] = [
            ("同人志 (Doujinshi)", 1),
            ("漫画 (Manga)", 2),
            ("画师CG (Artist CG)", 4),
            ("游戏CG (Game CG)", 8),
            ("欧美 (Western)", 512),
            ("非H (Non-H)", 256),
            ("图集 (Image Set)", 16),
            ("Cosplay", 32),
            ("亚洲 (Asian Porn)", 64),
            ("杂项 (Misc)", 128),
        ]

        return List {
            ForEach(allCategories, id: \.1) { name, bit in
                let isEnabled = (AppSettings.shared.defaultCategories & bit) != 0
                Toggle(name, isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        if newValue {
                            AppSettings.shared.defaultCategories |= bit
                        } else {
                            AppSettings.shared.defaultCategories &= ~bit
                        }
                    }
                ))
            }
        }
        .navigationTitle("默认搜索分类")
    }

    // MARK: - Excluded Tag Namespaces View (对齐 Android: ExcludedTagNamespacesActivity)

    private var excludedNamespacesView: some View {
        let namespaces: [(String, Int)] = [
            ("Reclass", 1),
            ("Language", 2),
            ("Parody", 4),
            ("Character", 8),
            ("Group", 16),
            ("Artist", 32),
            ("Male", 64),
            ("Female", 128),
            ("Mixed", 256),
            ("Cosplayer", 512),
            ("Other", 1024),
            ("Temp", 2048),
        ]

        return List {
            Section {
                Text("已选中的命名空间将从搜索结果的标签列表中排除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(namespaces, id: \.1) { name, bit in
                let isExcluded = (AppSettings.shared.excludedTagNamespaces & bit) != 0
                Toggle(name, isOn: Binding(
                    get: { isExcluded },
                    set: { newValue in
                        if newValue {
                            AppSettings.shared.excludedTagNamespaces |= bit
                        } else {
                            AppSettings.shared.excludedTagNamespaces &= ~bit
                        }
                    }
                ))
            }
        }
        .navigationTitle("排除的标签命名空间")
    }

    // MARK: - Excluded Languages View (对齐 Android: ExcludedLanguagesActivity)

    private var excludedLanguagesView: some View {
        let languages = [
            "Japanese", "English", "Chinese", "Dutch", "French",
            "German", "Hungarian", "Italian", "Korean", "Polish",
            "Portuguese", "Russian", "Spanish", "Thai", "Vietnamese",
            "N/A", "Other",
        ]

        return List {
            Section {
                Text("已选中的语言将从搜索结果中排除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(languages.enumerated()), id: \.offset) { index, lang in
                let bit = 1 << index
                let currentExcluded = Int(AppSettings.shared.excludedLanguages ?? "0") ?? 0
                let isExcluded = (currentExcluded & bit) != 0
                Toggle(lang, isOn: Binding(
                    get: { isExcluded },
                    set: { newValue in
                        var current = Int(AppSettings.shared.excludedLanguages ?? "0") ?? 0
                        if newValue {
                            current |= bit
                        } else {
                            current &= ~bit
                        }
                        AppSettings.shared.excludedLanguages = String(current)
                    }
                ))
            }
        }
        .navigationTitle("排除的语言")
    }
}

// MARK: - ViewModel

@Observable
class SettingsViewModel {
    var isLoggedIn = false
    var hasExAccess = false
    var displayName: String?
    var userId: String?
    var showLogoutConfirm = false
    var showLogin = false

    var gallerySite: Int = 0 {
        didSet { AppSettings.shared.gallerySite = EhSite(rawValue: gallerySite) ?? .eHentai }
    }
    var listMode: Int = 0 {
        didSet { AppSettings.shared.listMode = ListMode(rawValue: listMode) ?? .list }
    }
    var showJpnTitle: Bool = false {
        didSet { AppSettings.shared.showJpnTitle = showJpnTitle }
    }
    var showTagTranslations: Bool = true {
        didSet { AppSettings.shared.showTagTranslations = showTagTranslations }
    }
    
    // 标签数据库状态
    var isUpdatingTagDb = false
    var tagDbUpdateSuccess = false
    var tagDbStatus: String {
        let db = EhTagDatabase.shared
        if db.isLoaded {
            if let version = db.version {
                return "已加载 (\(version.prefix(10)))"
            }
            return "已加载"
        }
        return "未加载"
    }
    
    func updateTagDatabase() async {
        isUpdatingTagDb = true
        tagDbUpdateSuccess = false
        
        do {
            try await EhTagDatabase.shared.updateDatabase(forceUpdate: true)
            await MainActor.run {
                self.tagDbUpdateSuccess = true
                self.isUpdatingTagDb = false
            }
        } catch {
            print("[SettingsVM] Failed to update tag database: \(error)")
            await MainActor.run {
                self.isUpdatingTagDb = false
            }
        }
    }
    
    var domainFronting: Bool = false {
        didSet { AppSettings.shared.domainFronting = domainFronting }
    }
    var dnsOverHttps: Bool = false {
        didSet { AppSettings.shared.dnsOverHttps = dnsOverHttps }
    }
    var builtInHosts: Bool = false {
        didSet { AppSettings.shared.builtInHosts = builtInHosts }
    }
    var preloadImage: Int = 5 {
        didSet { AppSettings.shared.preloadImage = preloadImage }
    }
    var keepScreenOn: Bool = false {
        didSet { AppSettings.shared.keepScreenOn = keepScreenOn }
    }
    var multiThread: Int = 3 {
        didSet { AppSettings.shared.multiThreadDownload = multiThread }
    }
    var downloadTimeout: Int = 60 {
        didSet { AppSettings.shared.downloadTimeout = downloadTimeout }
    }
    var downloadDelay: Int = 0 {
        didSet { AppSettings.shared.downloadDelay = downloadDelay }
    }
    var autoPageInterval: Int = 5 {
        didSet { AppSettings.shared.autoPageInterval = autoPageInterval }
    }
    var historyInfoSize: Int = 100 {
        didSet { AppSettings.shared.historyInfoSize = historyInfoSize }
    }

    // 网络诊断状态
    var isDiagnosing = false
    var diagnosisResult = ""
    var diagnosisSuccess = false

    var diskCacheSize: String = "计算中..."

    func calculateCacheSize() {
        let urlCacheSize = URLCache.shared.currentDiskUsage
        let byteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useMB, .useGB]
        byteFormatter.countStyle = .file
        diskCacheSize = byteFormatter.string(fromByteCount: Int64(urlCacheSize))
    }

    func clearCache() {
        // 清除内存缓存
        GalleryCache.shared.clearAll()
        // 清除 URL 磁盘缓存
        URLCache.shared.removeAllCachedResponses()
        calculateCacheSize()
    }

    #if os(macOS)
    var downloadPath: String {
        if let path = UserDefaults.standard.string(forKey: "downloadPath"), !path.isEmpty {
            return path
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("download").path
    }

    func chooseDownloadPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择下载目录"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "downloadPath")
        }
    }
    #endif

    init() {
        // 从 AppSettings 加载初始值到 stored properties
        // (didSet 不会在 init 中触发，所以这些赋值不会写回 AppSettings)
        gallerySite = AppSettings.shared.gallerySite.rawValue
        listMode = AppSettings.shared.listMode.rawValue
        showJpnTitle = AppSettings.shared.showJpnTitle
        showTagTranslations = AppSettings.shared.showTagTranslations
        domainFronting = AppSettings.shared.domainFronting
        dnsOverHttps = AppSettings.shared.dnsOverHttps
        builtInHosts = AppSettings.shared.builtInHosts
        preloadImage = AppSettings.shared.preloadImage
        keepScreenOn = AppSettings.shared.keepScreenOn
        multiThread = AppSettings.shared.multiThreadDownload
        downloadTimeout = AppSettings.shared.downloadTimeout
        downloadDelay = AppSettings.shared.downloadDelay
        autoPageInterval = AppSettings.shared.autoPageInterval
        historyInfoSize = AppSettings.shared.historyInfoSize
        
        checkLoginState()
        calculateCacheSize()
    }

    func checkLoginState() {
        let ehCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://e-hentai.org")!) ?? []
        isLoggedIn = ehCookies.contains { $0.name == "ipb_member_id" }

        // ExH 访问权限: 只要已登录(有 memberId + passHash)就允许切换到 ExHentai
        // igneous Cookie 只有首次访问 exhentai.org 后才会被种下
        // Android 端同样允许已登录用户自由切换站点
        let exCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
        let hasIgneous = exCookies.contains { $0.name == "igneous" && !$0.value.isEmpty && $0.value != "mystery" }
        hasExAccess = isLoggedIn || hasIgneous

        // 加载保存的用户信息
        displayName = AppSettings.shared.displayName
        userId = AppSettings.shared.userId

        // 如果没有保存 UID，尝试从 Cookie 读取
        if userId == nil || userId?.isEmpty == true {
            if let memberId = ehCookies.first(where: { $0.name == "ipb_member_id" })?.value {
                userId = memberId
                AppSettings.shared.userId = memberId
            }
        }
    }

    func logout() {
        // 清除所有 EH 相关 Cookie
        let storage = HTTPCookieStorage.shared
        for domain in ["e-hentai.org", "exhentai.org", ".e-hentai.org", ".exhentai.org"] {
            if let cookies = storage.cookies(for: URL(string: "https://\(domain)")!) {
                for cookie in cookies { storage.deleteCookie(cookie) }
            }
        }
        isLoggedIn = false
        hasExAccess = false
        displayName = nil
        userId = nil
        AppSettings.shared.isLogin = false
        AppSettings.shared.displayName = nil
        AppSettings.shared.userId = nil
        AppSettings.shared.avatar = nil
    }
    
    /// 网络诊断
    func runNetworkDiagnostics() {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        diagnosisResult = ""
        diagnosisSuccess = false
        
        Task {
            var results: [String] = []
            var allSuccess = true
            
            // 1. DNS 解析测试
            let hosts = ["e-hentai.org", "exhentai.org"]
            for host in hosts {
                let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)
                CFHostStartInfoResolution(hostRef, .addresses, nil)
                if let addresses = CFHostGetAddressing(hostRef, &resolved)?.takeUnretainedValue() as? [Data], !addresses.isEmpty {
                    // 提取 IP 地址
                    if let addr = addresses.first {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        addr.withUnsafeBytes { ptr in
                            let sockaddr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                            getnameinfo(sockaddr, socklen_t(addr.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        }
                        let ip = String(cString: hostname)
                        results.append("✓ \(host) → \(ip)")
                    }
                } else {
                    results.append("✗ \(host) DNS 解析失败")
                    allSuccess = false
                }
            }
            
            // 2. HTTPS 连接测试
            for host in hosts {
                let url = URL(string: "https://\(host)/")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.httpMethod = "HEAD"
                
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 || httpResponse.statusCode == 302 {
                            results.append("✓ \(host) HTTPS 连接正常")
                        } else {
                            results.append("⚠ \(host) HTTP \(httpResponse.statusCode)")
                        }
                    }
                } catch let error as NSError {
                    if error.domain == NSURLErrorDomain {
                        switch error.code {
                        case NSURLErrorTimedOut:
                            results.append("✗ \(host) 连接超时")
                        case NSURLErrorCannotConnectToHost:
                            results.append("✗ \(host) 无法连接")
                        case NSURLErrorSecureConnectionFailed:
                            results.append("✗ \(host) TLS 错误 (可能被阻断)")
                        case NSURLErrorServerCertificateUntrusted:
                            results.append("✗ \(host) 证书不受信任")
                        default:
                            results.append("✗ \(host) 错误: \(error.localizedDescription)")
                        }
                    } else {
                        results.append("✗ \(host) 错误: \(error.localizedDescription)")
                    }
                    allSuccess = false
                }
            }
            
            // 3. 代理检测
            #if os(iOS)
            let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
            if let httpProxy = proxySettings?["HTTPProxy"] as? String, !httpProxy.isEmpty {
                results.append("ℹ 检测到 HTTP 代理: \(httpProxy)")
            }
            #endif
            
            await MainActor.run {
                self.diagnosisResult = results.joined(separator: "\n")
                self.diagnosisSuccess = allSuccess
                self.isDiagnosing = false
            }
        }
    }

    // MARK: - 下载管理 (对齐 Android)

    // MARK: - 恢复/清理 状态
    var isRestoring = false
    var restoreResultMessage: String?
    var isCleaning = false
    var cleanResultMessage: String?
    var showCleanConfirm = false
    var cleanOrphanCount = 0
    var cleanOrphanSize: String = ""

    /// 恢复下载项目 (对齐 Android: RestoreDownloadPreference)
    /// 扫描下载目录中的 .ehviewer 文件，将不在数据库中的画廊重新加入下载记录
    func restoreDownloadItems() {
        guard !isRestoring else { return }
        isRestoring = true
        restoreResultMessage = nil

        Task {
            let downloadDir = DownloadManager.shared.downloadDirectory
            var restoredCount = 0
            var errorCount = 0

            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.restoreResultMessage = "无法读取下载目录"
                    self.isRestoring = false
                }
                return
            }

            // 获取数据库中已有的 gid 集合
            let existingGids: Set<Int64>
            do {
                let records = try EhDatabase.shared.getAllDownloads()
                existingGids = Set(records.map { $0.gid })
            } catch {
                await MainActor.run {
                    self.restoreResultMessage = "数据库读取失败: \(error.localizedDescription)"
                    self.isRestoring = false
                }
                return
            }

            for dir in contents where dir.hasDirectoryPath {
                let ehviewerFile = dir.appendingPathComponent(".ehviewer")
                guard fm.fileExists(atPath: ehviewerFile.path) else { continue }

                // 读取 SpiderInfo 以获取 gid/token/pages
                guard let spiderInfo = SpiderInfoFile.read(from: dir) else { continue }
                guard spiderInfo.gid > 0, !spiderInfo.token.isEmpty else { continue }

                // 跳过已在数据库中的
                if existingGids.contains(spiderInfo.gid) { continue }

                // 从目录名提取标题: 格式为 "gid-title"
                let dirName = dir.lastPathComponent
                let prefix = "\(spiderInfo.gid)-"
                let title = dirName.hasPrefix(prefix) ? String(dirName.dropFirst(prefix.count)) : dirName

                // 统计已下载页数
                let imageFiles = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                    .map { $0.filter { url in
                        let ext = url.pathExtension.lowercased()
                        return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
                    }.count } ?? 0

                let record = DownloadRecord(
                    gid: spiderInfo.gid,
                    token: spiderInfo.token,
                    title: title,
                    pages: spiderInfo.pages,
                    state: imageFiles >= spiderInfo.pages ? DownloadManager.stateFinish : DownloadManager.stateNone,
                    date: Date()
                )

                do {
                    try EhDatabase.shared.insertDownload(record)
                    restoredCount += 1
                } catch {
                    errorCount += 1
                }
            }

            await MainActor.run {
                if restoredCount > 0 {
                    self.restoreResultMessage = "成功恢复 \(restoredCount) 个下载项目" + (errorCount > 0 ? " (\(errorCount) 个失败)" : "")
                } else {
                    self.restoreResultMessage = "没有需要恢复的下载项目"
                }
                self.isRestoring = false
            }
        }
    }

    /// 清除冗余数据 (对齐 Android: CleanRedundancyPreference)
    /// 扫描下载目录，找出不在数据库记录中的孤立文件夹，提示用户确认删除
    func cleanRedundancy() {
        guard !isCleaning else { return }
        isCleaning = true
        cleanResultMessage = nil

        Task {
            let downloadDir = DownloadManager.shared.downloadDirectory
            let fm = FileManager.default

            guard let contents = try? fm.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.cleanResultMessage = "无法读取下载目录"
                    self.isCleaning = false
                }
                return
            }

            // 获取数据库中所有 gid
            let dbGids: Set<Int64>
            do {
                let records = try EhDatabase.shared.getAllDownloads()
                dbGids = Set(records.map { $0.gid })
            } catch {
                await MainActor.run {
                    self.cleanResultMessage = "数据库读取失败"
                    self.isCleaning = false
                }
                return
            }

            // 找出孤立目录 (目录名以 gid- 开头，但 gid 不在数据库中)
            var orphanDirs: [URL] = []
            var totalSize: Int64 = 0
            for dir in contents where dir.hasDirectoryPath {
                let dirName = dir.lastPathComponent
                // 尝试提取 gid (格式: "gid-title")
                if let dashRange = dirName.firstIndex(of: "-"),
                   let gid = Int64(dirName[dirName.startIndex..<dashRange]) {
                    if !dbGids.contains(gid) {
                        orphanDirs.append(dir)
                        // 计算目录大小
                        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                            for case let fileURL as URL in enumerator {
                                let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                                totalSize += Int64(size)
                            }
                        }
                    }
                }
            }

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let sizeStr = formatter.string(fromByteCount: totalSize)

            await MainActor.run {
                if orphanDirs.isEmpty {
                    self.cleanResultMessage = "没有冗余数据"
                    self.isCleaning = false
                } else {
                    self.cleanOrphanCount = orphanDirs.count
                    self.cleanOrphanSize = sizeStr
                    self.showCleanConfirm = true
                    // isCleaning 保持 true 直到用户确认或取消
                }
            }
        }
    }

    /// 确认清除冗余数据 — 实际删除孤立目录
    func confirmCleanRedundancy() {
        Task {
            let downloadDir = DownloadManager.shared.downloadDirectory
            let fm = FileManager.default

            guard let contents = try? fm.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.cleanResultMessage = "清除失败"
                    self.isCleaning = false
                }
                return
            }

            let dbGids: Set<Int64>
            do {
                let records = try EhDatabase.shared.getAllDownloads()
                dbGids = Set(records.map { $0.gid })
            } catch {
                await MainActor.run {
                    self.cleanResultMessage = "清除失败"
                    self.isCleaning = false
                }
                return
            }

            var deletedCount = 0
            for dir in contents where dir.hasDirectoryPath {
                let dirName = dir.lastPathComponent
                if let dashRange = dirName.firstIndex(of: "-"),
                   let gid = Int64(dirName[dirName.startIndex..<dashRange]),
                   !dbGids.contains(gid) {
                    try? fm.removeItem(at: dir)
                    deletedCount += 1
                }
            }

            await MainActor.run {
                self.cleanResultMessage = "已清除 \(deletedCount) 个冗余目录"
                self.isCleaning = false
            }
        }
    }

    func cancelClean() {
        isCleaning = false
        cleanResultMessage = nil
    }

    /// 清除内存缓存
    func clearMemoryCache() {
        GalleryCache.shared.clearAll()
    }

    // MARK: - 数据导出/导入 (对齐 Android: ExportDataPreference / ImportDataPreference)

    var showImportPicker = false
    var showExportSuccess = false

    /// 导出数据: 将 UserDefaults 设置导出为 JSON
    func exportData() {
        let defaults = UserDefaults.standard
        let allKeys = [
            "gallery_site", "domain_fronting", "dns_over_https", "built_in_hosts",
            "multi_thread_download", "preload_image", "download_delay", "download_timeout",
            "download_origin_image", "image_resolution", "read_cache_size", "list_mode",
            "show_jpn_title", "show_tag_translations", "show_gallery_comment", "show_gallery_rating",
            "show_read_progress", "wide_screen_list_mode", "show_eh_events", "show_eh_limits",
            "default_categories", "excluded_tag_namespaces", "excluded_languages",
            "reading_direction", "page_scaling", "start_position", "keep_screen_on",
            "reading_fullscreen", "gallery_show_clock", "gallery_show_progress", "gallery_show_battery",
            "show_page_interval", "volume_page", "reverse_volume_page", "screen_rotation",
            "auto_page_interval", "color_filter", "default_favorite_2", "thumb_size",
            "detail_size", "thumb_resolution", "fix_thumb_url", "media_scan",
            "enable_secure", "security_delay", "save_parse_error_body", "history_info_size",
            "theme", "launch_page", "show_gallery_pages", "cellular_network_warning",
            "custom_screen_lightness", "screen_lightness",
        ]

        var exportDict: [String: Any] = [:]
        for key in allKeys {
            if let value = defaults.object(forKey: key) {
                exportDict[key] = value
            }
        }

        // 收藏夹名称
        for i in 0..<10 {
            if let name = defaults.string(forKey: "fav_cat_\(i)") {
                exportDict["fav_cat_\(i)"] = name
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: exportDict, options: .prettyPrinted) else {
            return
        }

        #if os(iOS)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ehviewer_settings.json")
        try? jsonData.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #else
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ehviewer_settings.json"
        panel.title = "导出设置"
        if panel.runModal() == .OK, let url = panel.url {
            try? jsonData.write(to: url)
        }
        #endif
    }

    /// 导入数据
    func importData() {
        showImportPicker = true
    }

    func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let defaults = UserDefaults.standard
        for (key, value) in dict {
            defaults.set(value, forKey: key)
        }

        // 重新加载 ViewModel 的存储属性
        gallerySite = AppSettings.shared.gallerySite.rawValue
        listMode = AppSettings.shared.listMode.rawValue
        showJpnTitle = AppSettings.shared.showJpnTitle
        showTagTranslations = AppSettings.shared.showTagTranslations
        domainFronting = AppSettings.shared.domainFronting
        dnsOverHttps = AppSettings.shared.dnsOverHttps
        builtInHosts = AppSettings.shared.builtInHosts
        preloadImage = AppSettings.shared.preloadImage
        keepScreenOn = AppSettings.shared.keepScreenOn
        multiThread = AppSettings.shared.multiThreadDownload
        downloadTimeout = AppSettings.shared.downloadTimeout
        downloadDelay = AppSettings.shared.downloadDelay
        autoPageInterval = AppSettings.shared.autoPageInterval
        historyInfoSize = AppSettings.shared.historyInfoSize
    }
}

#Preview {
    SettingsView()
}
