# EhViewer-Apple

[![GitHub Release](https://img.shields.io/github/v/release/felixchaos/EhViewer-Apple)](https://github.com/felixchaos/EhViewer-Apple/releases/latest)
[![Build](https://github.com/felixchaos/EhViewer-Apple/actions/workflows/build.yml/badge.svg)](https://github.com/felixchaos/EhViewer-Apple/actions/workflows/build.yml)
[![Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

用 SwiftUI 编写的 E-Hentai / ExHentai 客户端，支持 iPhone、iPad 和 Mac。功能与交互参考 Android 版 [EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ)，两端功能并不完全相同。

## 安装

| 平台 | 系统要求 | 获取方式 |
| --- | --- | --- |
| iPhone / iPad | iOS / iPadOS 18.0+ | [最新版 IPA](https://github.com/felixchaos/EhViewer-Apple/releases/latest)，需自行重签 |
| Mac | 当前源码要求 macOS 26.2+ | 用 Xcode 构建当前版；也可下载 [v1.3.1 的 DMG](https://github.com/felixchaos/EhViewer-Apple/releases/tag/v1.3.1) |

当前版本 **v1.3.4 只发布了 iPhone / iPad 安装包**，没有对应的 Mac DMG。v1.3.1 的 Mac 包不包含之后的修复。不提供 App Store 或 TestFlight 版本。

### iPhone / iPad

- **AltStore / SideStore**：可把下面的地址添加为更新源，或下载 IPA 后手动导入。
- **Sideloadly**：在 Windows 或 macOS 上导入 IPA，用你自己的 Apple ID 重签安装。

```text
https://raw.githubusercontent.com/felixchaos/EhViewer-Apple/main/source.json
```

项目不要求提交设备 UDID。请按签名工具的提示操作；重签期限和系统权限取决于签名方式。更新前不要先卸载旧版，以免删除本地收藏等数据。

最低版本以包内设置为准，不代表每个系统和设备组合都已实测。v1.3.4 通过了 iOS 和 macOS 构建校验，以及 iOS 26.5 模拟器的排行、分页和列表过滤回归测试；LiveContainer 真机环境尚未复测。

## 主要功能

- **浏览与搜索**：首页、热门、排行、订阅标签、快捷搜索、高级搜索、标签中文翻译和屏蔽规则。排行使用 E 站接口。
- **阅读**：横向翻页、纵向滚动、缩放和双页布局；可用的翻页方式随平台和设备而异。
- **下载**：下载队列、暂停与续传、下载记录与分组。
- **账号**：访客浏览、网页登录、Cookie 导入、本地及云端收藏。EX 和其他账号功能取决于站点实际权限。

## 从源码构建

建议用带当前 iOS、macOS SDK 的较新 Xcode；v1.3.4 已用 Xcode 27.2 测试。GitHub Actions 会选用构建镜像内较新的 Xcode。本地包的 Swift tools version 为 6.0。

```bash
git clone https://github.com/felixchaos/EhViewer-Apple.git
cd EhViewer-Apple
open "ehviewer apple.xcodeproj"
```

1. 等待 Swift Package 依赖解析，选择 `ehviewer apple` scheme。
2. 在 Mac 上运行时选择 **My Mac**。在 iPhone / iPad 上运行时，配置你自己的签名 Team 和唯一的 App Bundle ID；如果保留 Widget，扩展的签名和 Bundle ID 也需一并配置。
3. 选择目标设备，按 `⌘R`。使用真机时按 Xcode 和设备提示开启开发者模式并完成信任。

使用已安装的模拟器运行测试，例如：

```bash
xcodebuild test -project "ehviewer apple.xcodeproj" -scheme "ehviewer apple" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

如需自行分发 macOS 版本，仓库根目录的 [`distribute_mac.sh`](distribute_mac.sh) 可构建、签名、公证并生成 DMG。需要自己的 Developer ID Application 证书及 Apple 公证凭据；按脚本说明在本地设置 `APPLE_ID`、`TEAM_ID`、`APP_SPECIFIC_PASSWORD`，不要提交凭据。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `ehviewer apple/` | SwiftUI 应用、视图模型、平台集成和测试 |
| `Packages/EhCore/` | 数据模型、数据库和设置 |
| `Packages/EhNetwork/`、`Packages/EhParser/` | 请求、Cookie、DNS 和页面解析 |
| `Packages/EhSpider/`、`Packages/EhDownload/` | 图片获取与下载队列 |
| `Packages/EhUI/` | 可复用的界面组件 |

## 反馈与贡献

提交 [Issue](https://github.com/felixchaos/EhViewer-Apple/issues/new/choose) 时请注明 App 版本、设备及系统版本、安装方式和复现步骤。闪退可以附去掉个人信息的崩溃日志；请勿公开上传 Cookie 或账号凭据。

- [更新日志](CHANGELOG.md) · [贡献指南](CONTRIBUTING.md) · [安全报告](SECURITY.md) · [Apache License 2.0](LICENSE)
- 致谢 [EhViewer](https://github.com/Ehviewer-Overhauled/Ehviewer)、[EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ) 与 [GRDB.swift](https://github.com/groue/GRDB.swift)。

内容来自第三方站点，本项目不托管内容。请遵守所在地法律法规及站点规则。
