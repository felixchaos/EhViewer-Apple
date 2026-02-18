# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。

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
