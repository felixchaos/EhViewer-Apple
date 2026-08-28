# EhViewer-Apple

<p align="center">
  <img src="https://img.shields.io/badge/version-1.3.1-brightgreen" alt="Version"/>
  <img src="https://img.shields.io/badge/platform-iOS%2026.2%2B%20%7C%20macOS%2026%2B-blue" alt="Platform"/>
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift 6.0"/>
  <img src="https://img.shields.io/badge/license-Apache%202.0-green" alt="License"/>
</p>

用 SwiftUI 重写的 [E-Hentai](https://e-hentai.org) / [ExHentai](https://exhentai.org) 画廊客户端，支持 iPhone、iPad 和 Mac。

功能与交互对齐 Android 端的 [EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ)，网络层、解析器、下载引擎均为对照其实现重写，而非套壳。

---

## 安装

**本项目没有 TestFlight，也不会上架 App Store。** 内容形态不符合审核指南，请不要等待邀请。

| 平台 | 安装包 | 做法 | 有效期 |
|------|--------|------|--------|
| Mac | `.dmg` | 双击打开，拖进「应用程序」 | 1 年 |
| iPhone / iPad | `.ipa` | 用你自己的 Apple ID 签名后安装，见下文 | 免费账号 7 天，付费账号 1 年 |

安装包见 [Releases](../../releases)。iPhone 和 iPad 用的是同一个通用包。

### Mac

DMG 已用 Developer ID 签名并通过 Apple 公证，票据已植入，断网也能正常安装，不会出现
「无法打开，因为无法验证开发者」。双击挂载后把 App 拖进「应用程序」即可。

### iPhone / iPad

**本项目不收集设备 UDID。** 请用你自己的 Apple ID 给安装包签名——你的设备信息不需要
交给任何人，也不受开发者账号每年 100 台设备的限制。

常用工具，任选其一：

| 工具 | 运行环境 | 说明 |
|------|----------|------|
| [Sideloadly](https://sideloadly.io) | Windows / macOS | 连数据线，填 Apple ID，选 IPA，点开始 |
| [AltStore](https://altstore.io) / [SideStore](https://sidestore.io) | Windows / macOS | 装一次后可在设备上自助续签，不必每周接电脑 |

签名用的 Apple ID 建议单独注册一个，不要用主力账号。

免费账号签出的 App **7 天后失效**，重签即可，数据不会丢。付费开发者账号（$99/年）为 1 年。

关于重签的几点实测：

- 本项目的 entitlements 只有 `application-identifier` 和 `team-identifier`，**没有用 App Group、
  推送或关联域名**。这类权限在免费账号下无法申请，会被签名工具剥离并导致功能残缺——本项目不受影响。
- 下载进度的灵动岛显示走 ActivityKit，数据经 Live Activity 传递而非共享容器，重签后照常工作。
- widget 扩展会额外占用一个 App ID。免费账号每 7 天有 App ID 数量配额，正常使用够用；
  如果你短时间内反复重签多个 App 可能撞到上限，等配额恢复即可。

> 没有 Mac 也能装：Sideloadly 和 AltStore 都有 Windows 版本，签名在你自己的电脑上完成。
> 只有从源码编译才需要 macOS。

---

## 功能

**浏览与搜索**：首页、热门、排行榜、订阅标签列表；高级搜索支持分类、评分下限、页数范围与命名空间；标签选择器可按分组浏览并自动拼装搜索语法；标签中文翻译由 EhTagDatabase 提供。

**阅读器**：横向翻页与纵向滚动，双页排版（iPad / Mac），双指缩放，点击分区翻页，GIF 动图，键盘与外置蓝牙翻页器，音量键翻页，护眼色彩滤镜。

**下载**：后台下载、断点续传、标签分组、通知与灵动岛进度、阅读时同步下载、按标题或标签搜索、打包为 zip 分享。

**账号**：网页登录、Cookie 粘贴登录、访客浏览；收藏夹云端同步；评论发表与编辑；图片配额查看与重置；我的标签管理。

**资源**：归档下载与 H@H 派发、种子列表、站内公告。

**网络容灾**：内置 IP 表与自定义 Hosts、域名前置回退、DNS over HTTPS、H@H 节点自动切换。

---

## 环境要求

| 项目 | 版本 |
|------|------|
| Xcode | 26.0+ |
| Swift | 6.0 |
| iOS / iPadOS | 26.2+ |
| macOS | 26.0+ |

系统要求较高是因为代码大量使用了 Swift 6 严格并发与 iOS 26 的 SwiftUI API（`@Observable`、`scrollPosition`、`ContentUnavailableView` 等）。降低最低版本需要成规模的重写，目前没有计划。

---

## 从源码构建

```bash
git clone https://github.com/felixchaos/EhViewer-Apple.git
cd EhViewer-Apple
open "ehviewer apple.xcodeproj"
```

首次打开会自动解析 Swift Package 依赖，可能需要几分钟。

### 在 Mac 上运行

选择 `ehviewer apple` scheme，目标设备选 **My Mac**，按 `⌘R`。

### 安装到 iPhone / iPad

需要一个 Apple ID（免费即可）和一根数据线。

1. 用数据线连接设备，在设备上选择「信任此电脑」
2. Xcode → **Settings → Accounts**，添加你的 Apple ID
3. 选中项目 → **Signing & Capabilities**，Team 选你的账号
4. Bundle Identifier 改成唯一值（例如 `com.yourname.ehviewer`），否则会和他人冲突
5. 目标设备选你的设备，按 `⌘R`

首次安装后，设备上前往 **设置 → 通用 → VPN 与设备管理**，信任你的开发者描述文件。

免费账号签名的应用 **7 天后失效**，需要重新连接 Mac 安装。付费账号（$99/年）为 1 年。

### 构建 macOS 分发包

`distribute_mac.sh` 会完成签名、公证、打包全流程，产出一个可直接分发、不触发 Gatekeeper 警告的 `.dmg`。需要付费开发者账号。

**准备 App 专用密码** — 公证服务不接受 Apple ID 登录密码：

1. 登录 [appleid.apple.com](https://appleid.apple.com/) → **登录和安全 → App 专用密码**
2. 生成一个（标签随意，如 `ehviewer-notarize`）
3. 记下形如 `xxxx-xxxx-xxxx-xxxx` 的密码，**只会显示一次**

**查找 Team ID** — 在 [developer.apple.com/account](https://developer.apple.com/account) 的 Membership Details 里，是一串 10 位字母数字。或者：

```bash
security find-identity -v -p codesigning | grep "Developer ID"
```

**确认证书** — Xcode → **Settings → Accounts → Manage Certificates**，确保有 **Developer ID Application**，没有就点左下角 `+` 创建。

**配置凭据** — 在仓库根目录建 `.env`（已在 `.gitignore` 中）：

```bash
APPLE_ID=your-email@example.com
TEAM_ID=HWZEUNLCY6
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

**运行**：

```bash
cd "ehviewer apple"
./distribute_mac.sh
```

脚本依次执行 Release 归档、Developer ID 导出、Hardened Runtime 深度签名、创建 DMG、提交 Apple 公证并等待结果、植入公证票据。完成后 `.dmg` 在 `build/` 目录下。

Developer ID 证书有效期 1 年，到期在 Xcode 里续签后重新运行即可。

---

## 项目结构

App 层只放视图，业务逻辑全部下沉到 `Packages/` 下的本地 Swift Package，各模块可独立编译和测试。

```
EhViewer-Apple/
├── ehviewer apple/              # 主 App：SwiftUI 视图层
├── Packages/
│   ├── EhCore/
│   │   ├── EhModels/            # 数据模型、URL 构建器
│   │   ├── EhDatabase/          # GRDB 持久化
│   │   └── EhSettings/          # 全局配置、标签数据库
│   ├── EhNetwork/
│   │   ├── EhAPI/               # 请求引擎，对照 Android EhEngine
│   │   ├── EhCookie/            # Cookie 管理
│   │   └── EhDNS/               # 内置 Hosts 与域名前置
│   ├── EhParser/                # HTML / JSON 解析器
│   ├── EhSpider/                # 图片抓取与本地存储
│   ├── EhDownload/              # 下载队列
│   └── EhUI/                    # 复用组件
└── ehviewer apple.xcodeproj/
```

跑测试：

```bash
xcodebuild test -project "ehviewer apple.xcodeproj" -scheme "ehviewer apple" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

## 参与贡献

提 issue 时请附上设备型号、系统版本和复现步骤；如果是网络问题，说明你的代理方式会更好定位。

提 PR 前请确认 iOS 和 macOS 两个目标都能编译，并跑通测试。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 其他

- 更新记录见 [CHANGELOG.md](CHANGELOG.md)
- 开源协议 [Apache License 2.0](LICENSE)

致谢 [EhViewer](https://github.com/Ehviewer-Overhauled/Ehviewer)、[EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ) 与 [GRDB.swift](https://github.com/groue/GRDB.swift)。

本项目仅供学习与技术交流。使用者需遵守所在地法律法规，开发者不对使用本软件产生的后果负责。
