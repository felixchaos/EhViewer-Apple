# EhViewer Apple 全面代码审计报告

> 审计范围: 全部 6 个 Swift Package + 主应用目标 (~50+ Swift 文件, ~20,000+ 行)  
> Swift 6.0 / iOS 17+ / macOS 14+ / SwiftUI + @Observable

---

## 一、架构总览

```
┌──────────────────────────────────────────────────────────┐
│                      主应用 (ehviewer apple)               │
│  Views: GalleryListView, GalleryDetailView,              │
│         ImageReaderView, DownloadsView, SettingsView...   │
│  VMs:   ReaderViewModel, GalleryCache, ErrorHandler       │
│  Services: GalleryActionService, BackgroundDownloadMgr    │
└──────────────────────┬───────────────────────────────────┘
                       │ depends on
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
  ┌──────────┐  ┌───────────┐  ┌──────────┐
  │  EhUI    │  │ EhDownload│  │ EhSpider │
  │(SDWebImg)│  │(DownloadMgr)│ │(SpiderQ) │
  └────┬─────┘  └─────┬─────┘  └────┬─────┘
       │              │              │
       ├──────────────┼──────────────┘
       ▼              ▼
  ┌──────────┐  ┌───────────┐
  │ EhNetwork│  │ EhParser  │
  │(EhAPI)   │  │(SwiftSoup)│
  └────┬─────┘  └─────┬─────┘
       │              │
       └──────┬───────┘
              ▼
        ┌──────────┐
        │  EhCore  │
        │(Models,  │
        │ Settings,│
        │ Database)│
        └──────────┘
```

### 包级依赖关系

| 包 | 依赖 | 核心职责 |
|---|---|---|
| **EhCore** | Foundation, GRDB | 数据模型、AppSettings、EhDatabase、EhRateLimiter |
| **EhParser** | EhCore, SwiftSoup | HTML 页面解析 |
| **EhNetwork** | EhCore, EhParser | EhAPI (actor)、Cookie 管理、DNS 解析 |
| **EhSpider** | EhCore, EhNetwork, EhParser | SpiderQueen/SpiderDen — 图片加载引擎 |
| **EhDownload** | EhCore, EhSpider | DownloadManager — 下载任务管理 |
| **EhUI** | 所有上述包 + SDWebImageSwiftUI | 共享 UI 组件 |

---

## 二、并发安全审计

### C-1: `@unchecked Sendable` 逐项审查 [已完成]

| 文件 | 类 | 风险 | 处理 |
|---|---|---|---|
| AppSettings.swift | `AppSettings` | 所有属性 `@ObservationIgnored`，`@Observable` 失效 | ✅ R-6: 15 个 UI 属性改用 access/withMutation |
| EhCookieManager.swift | `EhCookieManager` | HTTPCookieStorage.shared 线程安全 | ✅ 无需修改 |
| EhDNS.swift | `EhDNS` | `userHosts` 有 NSLock 保护 | ✅ 无需修改 |
| GalleryCache.swift | `GalleryCache` | NSCache 线程安全 | ✅ 无需修改 |
| CachedAsyncImage.swift | `ThumbnailMemoryCache` | NSCache 线程安全 | ✅ 无需修改 |
| SpiderDen.swift | `SimpleDiskCache` | `contains`, `getData`, `set` 无 queue 保护 | ✅ R-2: 全部包裹 queue.sync |
| BackgroundDownloadManager.swift | `BackgroundDownloadManager` | `activeTasks` 字典被 URLSession delegate 和调用方并发访问 | ✅ R-8: 添加 NSLock 保护 |
| DownloadNotificationService.swift | `DownloadNotificationService` | 已标记 `@MainActor` — 安全 | ✅ 无需修改 |
| DownloadNotificationBridge.swift | `DownloadNotificationBridge` | 无可变状态 — 安全 | ✅ 无需修改 |
| EhTagDatabase.swift | `EhTagDatabase` | 已有 DispatchQueue barrier 保护 | ✅ 无需修改 |
| EhFilterManager.swift | `EhFilterManager` | `@Observable` + 可变 filters 无同步 | ✅ R-9: 添加 `@MainActor` |
| FavouriteStatusRouter.swift | `FavouriteStatusRouter` | `@Observable` + 可变 maps/nextId 无同步 | ✅ R-10: 添加 `@MainActor` |
| EhAPI.swift | `DomainFrontingDelegate` | 仅 `let` 属性，不可变 | ✅ 无需修改 |
| DownloadManager.swift | `SpiderInfoUpdater` | `downloadedCount`/`lastNotifyTime` 被 TaskGroup 并发调用 | ✅ R-11: 转为 `actor` |

### C-2: `nonisolated(unsafe)` 逐项审查 [已完成]

| 文件 | 变量 | 风险 | 处理 |
|---|---|---|---|
| SpiderDen.swift | `_readCache`, `_cacheInitialized` | check-then-write 非原子 | ✅ R-3: NSLock 保护 |
| GalleryDetailView.swift | `downloadPollingTask` | ViewModel 被 View(@MainActor) 使用 | ✅ R-7: 类加 `@MainActor` 移除 unsafe |
| GalleryListParser.swift | 6 个 static let 正则 | `static let` 有 dispatch_once 语义，Regex 非 Sendable 的已知限制 | ✅ 安全，无需修改 |

### C-3: ErrorHandler 混用 GCD [已修复]

`DispatchQueue.main.async` → `Task { @MainActor in }`, 类加 `@MainActor`。

### C-4: SpiderQueen `[weak self]` 在 actor 中 [低]

Actor 方法中的 Task 闭包使用 `[weak self]` — 保守做法，保留。

---

## 三、内存管理审计

### M-1: ReaderViewModel 250MB 固定缓存 [已修复]

iPhone SE (3GB) 上 250MB 图片缓存即占 ~8% 物理内存。

✅ R-4: 改为设备自适应:
- < 4GB → 80MB
- 4-6GB → 150MB
- 6-8GB → 250MB
- \> 8GB → 400MB

### M-2: `cachedImages` 字典无大小限制 [已修复]

Observable 层的 `cachedImages: [Int: PlatformImage]` 在快速滑动时可能积累大量图片。`evictDistantPages()` 仅在 `onPageChange()` 调用。

✅ R-5: 在 `downloadImageData()` 解码成功后立即调用 `evictDistantPages()`，确保距离远的页面被及时释放。

### M-3: 双页合成临时大图 [低]

合成两张 4096×6000 页面 → ~196MB 临时图。有安全阀但合成产物不入 NSCache。
保留现状 — 安全阀机制足够。

### M-4: Timer 与 NotificationCenter 生命周期 [验证通过]

| 组件 | Timer | 清理 | 结论 |
|---|---|---|---|
| ImageReaderView | `timeTimer` (60s 间隔) | `cleanupReader()` → `invalidate()` → `.onDisappear` | ✅ 安全 |
| SecurityView | `lockoutTimer` (1s 间隔) | 多处 `invalidate()` + `= nil` | ✅ 安全 |
| DownloadsView | `refreshTimer` (1s 间隔) | `[weak self]` + 自动停止 + 手动 `invalidate()` | ✅ 安全 |

---

## 四、SwiftUI 最佳实践

### S-1: AppSettings `@Observable` 完全失效 [已修复]

全部 ~50 个属性 `@ObservationIgnored` → SwiftUI 永远不会因设置变化而刷新。

✅ R-6: 15 个 UI 驱动属性 (`gallerySite`, `listMode`, `showJpnTitle`, `isLogin`, `displayName`, `theme` 等) 改用 `access(keyPath:)/withMutation(keyPath:)` 实现正确的 Observation 通知。其余后端属性 (`downloadTimeout`, `domainFronting` 等) 保持 `@ObservationIgnored` 以避免不必要的重绘。

### S-2: GalleryDetailViewModel 冗余 MainActor hop [已修复]

`loadDetail()`、`rateGallery()`、`loadAllComments()` 等方法内有 10 处 `await MainActor.run { ... }`。

✅ R-7: ViewModel 加 `@MainActor` 后，所有方法已在 MainActor 执行，移除全部冗余 `await MainActor.run { ... }` 块。

### S-3: 巨型 View 文件 [建议]

| 文件 | 行数 | 建议拆分 |
|---|---|---|
| GalleryListView.swift | 1,872 | 搜索栏 → `GallerySearchBar.swift`、列表项 → `GalleryRowView.swift` |
| SettingsView.swift | 1,806 | 各分组 → 独立 `*SettingSection.swift` |
| ImageReaderView.swift | 1,567 | 工具栏 → `ReaderToolbarView.swift`、页面渲染 → `PageContentView.swift` |
| GalleryDetailView.swift | 1,234 | 标签区 → `GalleryTagsSection.swift`、预览网格 → `PreviewGridView.swift` |

---

## 五、业务流程审计

### 启动流程

```
ehviewer_appleApp.init()
  → AppDelegate (macOS: NSApplicationDelegate)
  → RootView
    → SecurityView (如果 enableSecurity)
    → SelectSiteView (如果 !hasSelectedSite)
    → WarningView (如果 showWarning)
    → MainTabView
      └── GalleryListView (首页)
```

### 登录流程

```
SettingsView → LoginView
  → EhAPI.shared.login(username, password)   [actor]
  → 解析 Cookie (EhCookieManager)
  → 更新 AppSettings.shared.isLogin
  → 检查 ExHentai 权限 (igneous cookie)
```

### 数据加载流程

```
GalleryListView.loadGalleries()
  → GalleryCache.shared.getListResult(forKey:)   [NSCache, 线程安全]
  → 缓存 miss: EhAPI.shared.getGalleryList(url:)  [actor]
    → EhRequestBuilder.buildRequest()              [构造 URLRequest]
    → URLSession.shared.data(for:)                 [4 种会话策略]
    → GalleryListParser.parse(html:)               [SwiftSoup]
  → 结果存入 GalleryCache + EhDatabase
  → SwiftUI body 刷新列表
```

### 图片阅读流程

```
GalleryDetailView → ImageReaderView(gid:, token:, pages:, startPage:)
  → ReaderViewModel 初始化 NSCache (设备自适应)
  → preloadPages(around: currentPage, range: 3)
    → SpiderQueen.shared(for: gid).getImageUrl(index:)  [actor]
    → downloadImageData(index:, urlStr:)
      → URLSession 下载 + PlatformImage 解码
      → cachedImages[index] = img + evictDistantPages()
  → ZoomableImageView 渲染
```

---

## 六、已执行重构清单

| ID | 文件 | 修改内容 | 验证 |
|---|---|---|---|
| **R-1** | AppErrorHandling.swift | `ErrorHandler` → `@MainActor`, `handle()`/`handleSilently()` → `nonisolated`, GCD → `Task { @MainActor in }` | ✅ 0 errors |
| **R-2** | SpiderDen.swift | `SimpleDiskCache` 的 `contains`/`getData`/`set`/`remove` 包裹 `queue.sync` | ✅ 0 errors |
| **R-3** | SpiderDen.swift | 静态变量 `_readCache`/`_cacheInitialized` 加 NSLock 保护 + 线程安全 computed property | ✅ 0 errors |
| **R-4** | ReaderViewModel.swift | NSCache `totalCostLimit` 从固定 250MB → 依据 `physicalMemory` 动态设定 (80-400MB) | ✅ 0 errors |
| **R-5** | ReaderViewModel.swift | `downloadImageData()` 中解码成功后立即调用 `evictDistantPages()` | ✅ 0 errors |
| **R-6** | AppSettings.swift | 15 个 UI 属性改用 `access(keyPath:)/withMutation(keyPath:)` + `_defaults` 统一访问 | ✅ 0 errors |
| **R-7** | GalleryDetailView.swift | `GalleryDetailViewModel` → `@MainActor`, 移除 `nonisolated(unsafe)`, 删除 8 处冗余 `await MainActor.run` | ✅ 0 errors |
| **R-8** | BackgroundDownloadManager.swift | `activeTasks` 字典访问加 `tasksLock: NSLock` 保护 | ✅ 0 errors |
| **R-9** | EhFilterManager.swift | 添加 `@MainActor` 保护可变 `filters` 数组 | ✅ 0 errors |
| **R-10** | FavouriteStatusRouter.swift | 添加 `@MainActor` 保护可变 `maps`/`nextId` | ✅ 0 errors |
| **R-11** | DownloadManager.swift | `SpiderInfoUpdater` 从 `final class @unchecked Sendable` → `actor` | ✅ 0 errors |

---

## 七、无需修改的确认项

| 项目 | 理由 |
|---|---|
| `GalleryCache: @unchecked Sendable` | NSCache 本身线程安全 |
| `ThumbnailMemoryCache: @unchecked Sendable` | NSCache 本身线程安全 |
| `EhCookieManager: @unchecked Sendable` | 仅使用 HTTPCookieStorage.shared (线程安全) |
| `EhDNS: @unchecked Sendable` | `userHosts` 有 NSLock，静态 `builtInHosts` 不可变 |
| `EhTagDatabase: @unchecked Sendable` | 已有 concurrent DispatchQueue + barrier 写保护 |
| `DomainFrontingDelegate: @unchecked Sendable` | 仅有 `let` 属性，不可变 |
| `DownloadNotificationService: @unchecked Sendable` | 已标记 `@MainActor`，全部状态在主线程同步 |
| `DownloadNotificationBridge: @unchecked Sendable` | 无可变状态，仅转发方法调用 |
| `GalleryListParser.nonisolated(unsafe) static let` | 正则 `static let` 有 dispatch_once 语义 |
| SpiderQueen `[weak self]` | 保守做法，保留 |
| Timer 生命周期管理 | 三处 Timer 均有正确的 invalidate 清理 |
