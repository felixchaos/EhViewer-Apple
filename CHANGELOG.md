# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。

## [未发布]

### 🐛 修复线上 issue

- **下载管理删除/恢复任务闪退** (#8 问题四) — `executeDownload` 跨 `await` 持有数组索引，挂起期间删除任务导致越界；改为全程按 gid 定位 + `runningGid` 令牌校验
- **暂停/删除停不下正在跑的下载** — `activeTask` 是值拷贝，`spider` 是之后才写进队列的，`activeTask?.spider` 恒为 nil，`cancelAll()` 一直调在空值上
- **最低评分过滤失效** (#8 问题三) — 首页模式构建 URL 时丢掉了 `advanceSearch/minRating/pageFrom/pageTo`，无关键字时评分过滤静默失效
- **画廊列表循环** (#8 问题一) — 缓存命中未恢复分页游标、缓存 key 未含筛选条件、ptt 末页回绕的 `nextHref` 未丢弃、快速搜索未记录游标
- **下载完成仍无法离线阅读** (#8 问题二) — `downloadQueue` 改为 lazy 同步加载（消除启动竞态）；本地读取由"整本完成"放宽为逐页判断
- **阅读时 TLS 错误 / 加载不出图片** (#6) — 阅读器不再用裸 `URLSession` 直连，页面请求走 `EhAPI`（含域名前置回退）；新增 H@H 节点切换重试（`?nl=`）
- **外置翻页器无法翻页** (#4) — 阅读器补上 `focusable`（iOS 上 `onKeyPress` 依赖焦点）、PageUp/PageDown/Home/End 不再限 macOS、实现音量键翻页

### ✨ 收尾补齐

- **IP 封禁提示** (#1) — 服务端返回封禁页时是正常 200，解析出 0 条画廊，界面此前是一片空白；
  新增 `EhError.ipBanned` 检测并带出解封倒计时，错误页给出「换节点」这一唯一有效动作
- **分享已下载画廊** (#2) — 下载列表长按「分享 (打包为 zip)」，用 `NSFileCoordinator`
  的 `.forUploading` 生成 zip 后唤起系统分享，无需引入第三方压缩库
- **账号资料与配额** — 头像 / UID / 图片配额进度条 / 花 GP 重置；
  `getHomeDetail` 与 `resetLimit` 此前从无调用方
- **自定义 Hosts** — 对齐 Android HostsActivity；顺带补上持久化（原来只在内存里，重启即丢）

### 🐛 阅读器按键回归修复

- **切换阅读方向弹出软键盘** — 上一版为支持外置翻页器给阅读器加了 SwiftUI `.focusable()`，
  但在 iOS 上程序化聚焦一个普通视图会让它成为文本输入目标；打开 Picker / Menu 时
  UIKit 为"输入首字母跳选"开文本输入会话，就把软键盘调了出来。
  改为走 UIKit responder chain (`KeyCommandCatcher`)，并给它一个零高度 `inputView`：
  按键照收，键盘不再出现。
- **方向键含义与点击区域不一致** — 左方向键原本等同"右侧点击区"，和 `handleTapZone`
  以及 Android 的 `KEYCODE_DPAD_LEFT` 都相反，现已对齐

### 🔄 对齐 Android 上游 (2026-02-12 → 2026-08-21)

- **种子解析重写** — 按 `<form>` 分块解析，新增上传时间 `TorrentInfo.posted`，正则容忍 EH 的换行排版
- **可编辑评论接口** — 新增 `geteditcomment` API + `GetEditCommentParser`，取回评论原始 BBCode
- **搜索词换行过滤** — 粘贴带 `\r\n` 的标签不再拆断 `artist:foo` 语法
- **SpiderInfo 头部读取** — 新增 `readHeader`，扫描下载目录时不再逐本解析上万条 pToken；补文件体积上限防 OOM
- **阅读时同步下载** — 新增设置项，浏览未下载画廊时把看过的图片存进下载目录

### ✨ 登录页重做

- **网页登录提升为主操作** — 账号密码登录经常被 Cloudflare 人机验证拦下，却一直占着主位；现在主推内嵌浏览器登录，三种方式各带一句说明
- **Cookie 支持整段粘贴** — 不再要求手工拆成三个字段，分号分隔 / 请求头 / Cookie 导出插件的 JSON 都能识别，实时显示识别结果（值做掩码）
- **访客入口改为正式按钮** — 原来是灰色小字，看起来不像能点；并说明访客的功能限制
- iOS 用系统 `PasteButton`，避免每次粘贴都弹授权框

### 🚀 功能补齐 (按审查排期)

- **归档 / H@H 下载界面** (issue #3) — 详情页新增入口，H@H 规格派发 + 归档直链下载
- **种子列表** — 文件名、上传时间、下载 / 分享 / 复制链接
- **15 个空转的设置项全部接上逻辑** — 其中 5 项靠新增的 `EhConfigSync` 写入 uconfig Cookie（`EhConfig` 序列化器早就写好但从没被调用）；`mediaScan` 是 Android 概念，直接删除
- **评论发表 / 编辑** — 编辑先经 `geteditcomment` 取回原始 BBCode，避免把自己的排版改没
- **下载列表按标签搜索** — 详情加载时把标签写入 `galleryTags` 表（建了表但从没写过），搜索按空格拆词做 AND 匹配
- **标签选择器** — 按命名空间分组浏览，点选自动拼成 `f:xxx$` 语法
- **我的标签 / 站内公告** — 原生页面，替掉设置页里"打开网页"的临时做法
- **订阅列表独立入口** — 新增底部标签页，走 `/watched`

### 🧪 测试

- 新增 19 个单元测试（分页游标解析、高级搜索 URL、种子解析、可编辑评论、搜索词清洗）
- 修复 `ehviewer apple` scheme 缺少 TestAction、测试文件被编进 App target 两个工程配置问题

---

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
