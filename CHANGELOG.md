# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。

## [1.2.1] - 2026-02-20

### 🔧 阅读器体验优化 + ExHentai 修复

#### Bug 修复
- **修复搜索失效** — `@Observable` 宏使 `didSet` 在 `init()` 中也会触发，导致 `siteChangedNotification` 误刷新列表覆盖搜索结果
- **修复切换 ExHentai 后重启回退** — 移除 `validateExHentaiAccess()` 对 igneous Cookie 的错误检查，已登录用户可自由切换站点（对齐 Android）
- **修复 ExHentai 站点切换无效** — `siteBaseURL` 不再依赖 igneous Cookie（鸡生蛋死循环），改为检查登录 Cookie
- **修复下载进度卡在 0%** — `URLSession.download(for:delegate:)` 不转发进度回调，改用 `bytes(for:)` 流式下载 + 16KB 分块写入
- **修复纵向滚动阅读器卡顿** — 轻量化图片预处理、100ms 滚动去抖、节流进度更新

#### 新功能
- **GIF 动图支持** — 阅读器和缩略图支持 GIF 动画播放
- **应用内检查更新** — 设置页新增「检查更新」，自动/手动检查 GitHub Releases 最新版本
- **纯黑阅读器背景** — 阅读器背景改为纯黑色，移除 CIAreaAverage 计算
- **默认纵向滚动** — 阅读方向默认改为从上到下纵向滚动

#### 改进
- 站点切换后列表自动刷新（对齐 Android 行为）
- ExHentai 可用提示不再重复弹出（已在 ExHentai 时跳过）

---

## [1.2.0] - 2026-02-18

### 🔧 阅读器手势与导航全面修复

#### Bug 修复
- **修复图片加载后手势失效** — SwiftUI ScrollView 不走 UIKit failure chain，改用 `panGestureRecognizer.isEnabled` 彻底禁用内层手势竞争
- **修复缩略图预览进入阅读器页面错位** — `lazyCurrentPage` 未同步 `initialPage`，`.onChange` 不触发初始值导致 ScrollView 始终显示第 0 页
- **修复多层手势冲突** — 重写 `gestureRecognizerShouldBegin()` 为三级优先级逻辑：边缘返回 > 无滚动透传 > 边缘翻页
- **修复翻页手势只触发一次** — 移除错误的 `panGestureRecognizer.isEnabled = false` 设置
- **修复 FaceID 认证无限循环** — SecurityView 认证状态机修复
- **修复阅读器四个关键问题** — 滑动手势冲突、垂直模式点击区域、页码重复显示、FaceID 崩溃

#### 性能优化
- `@ObservationIgnored` 标记非 UI 属性，减少不必要的视图重绘
- 批量驱逐远距离页面缓存
- 翻页去抖 80ms debounce

---

## [1.1.0] - 2026-02-18

### 🚀 首个正式 Release

提供 iPhone / iPad / Mac 多平台安装包。

#### Bug 修复
- 修复左右翻页手势丢失 — ZoomableScrollView 初始化正确禁用内层滚动
- 修复标签搜索列表点击画廊导航循环和错乱
- 修复启动页面设置无法反映到 iPhone 底部导航栏
- 修复热门列表点击画廊报错
- 修复启动页面 Picker 下拉菜单无法点击
- 修复 HistoryView 重复注册 navigationDestination 警告
- 修复 ReaderViewModel Main actor isolation 构建错误

#### 架构改进
- NavigationLink 统一采用 value-based API
- Tab.bottomTabs 改为动态计算属性
- maxDecodePixelSize 使用固定值避免 actor isolation 问题

#### 并发安全
- SpiderDen 静态可变状态 NSLock 保护
- DownloadManager.SpiderInfoUpdater 迁移为 actor
- GalleryDetailViewModel 标注 @MainActor
- AppSettings UI 属性支持 @Observable

#### 内存优化
- NSCache 容量自适应设备内存 (80–400 MB)
- 翻页时主动驱逐远距离页面

---

## [0.1.0] - 2026-02-15

### 🎉 首次发布

#### 新功能
- **画廊浏览** — 支持 E-Hentai / ExHentai 画廊列表、热门、最新
- **排行榜** — TopList 排行榜浏览
- **高级搜索** — 分类筛选、关键词、标签搜索
- **快速搜索** — 搜索条件收藏与快速调用
- **收藏管理** — 多文件夹云端收藏同步
- **浏览历史** — 本地浏览记录管理
- **画廊详情** — 标签、评论、预览图、元数据展示
- **图片阅读器** — 横向翻页 / 纵向滚动双模式
  - 缩放手势支持（水平/纵向模式）
  - 滑动返回手势
  - HUD 叠加层（电量、时间、进度）
- **下载管理** — 后台下载、断点续传、进度通知
- **多种登录方式** — 账号密码、网页登录、Cookie 导入、跳过登录
- **安全保护** — Face ID / Touch ID / 密码锁
- **站点切换** — E-Hentai / ExHentai 一键切换
- **设置中心** — 阅读器偏好、网络配置、数据管理

#### 网络
- Domain Fronting 回退机制
- DNS over HTTPS 支持
- Cloudflare 403 检测与友好提示
- WebView 原生 UA 登录（兼容 Cloudflare Turnstile）

#### 平台支持
- iOS 17+ / iPadOS 17+
- macOS 14+ (Sonoma)

#### 架构
- Swift Package Manager 模块化架构（EhCore、EhNetwork、EhParser、EhSpider、EhDownload、EhUI）
- Swift 6 严格并发安全
- SwiftUI 原生构建
