# EhViewer-Apple

[![GitHub Release](https://img.shields.io/github/v/release/felixchaos/EhViewer-Apple)](https://github.com/felixchaos/EhViewer-Apple/releases/latest)
[![Build](https://github.com/felixchaos/EhViewer-Apple/actions/workflows/build.yml/badge.svg)](https://github.com/felixchaos/EhViewer-Apple/actions/workflows/build.yml)
[![Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

用 SwiftUI 编写的 E-Hentai / ExHentai 客户端，支持 iPhone、iPad 和 Mac。功能与交互参考 Android 版 [EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ)，两端功能并不完全相同。

## 安装

| 平台 | 系统要求 | 获取方式 |
| --- | --- | --- |
| iPhone / iPad | iOS / iPadOS 18.0+ | 从 [最新发布](https://github.com/felixchaos/EhViewer-Apple/releases/latest) 下载 IPA，重签后安装 |
| Mac | 当前源码要求 macOS 26.2+ | 使用 Xcode 构建；历史 DMG 见 [Releases](https://github.com/felixchaos/EhViewer-Apple/releases) |

最新发布仅提供 iPhone / iPad 的 IPA，不含 Mac 安装包。历史 DMG 不包含后续修复，安装要求以对应的发布说明为准。不提供 App Store 或 TestFlight 版本。

### iPhone / iPad

- **AltStore / SideStore**：可把下面的地址添加为更新源，或下载 IPA 后手动导入。
- **Sideloadly**：在 Windows 或 macOS 上导入 IPA，用你自己的 Apple ID 重签安装。

```text
https://raw.githubusercontent.com/felixchaos/EhViewer-Apple/main/source.json
```

项目不要求提交设备 UDID。请按签名工具的提示操作；重签期限和系统权限取决于签名方式。更新前不要先卸载旧版，以免删除本地收藏等数据。

最低系统版本以安装包为准。iPhone Duo 的内外屏布局在模拟器上验证；不等同于真机或 LiveContainer 兼容性验证。

## 主要功能

| 功能 | 说明 |
| --- | --- |
| 浏览与搜索 | 支持首页、热门、排行、订阅标签、高级搜索以及标签翻译和屏蔽。订阅页默认搜订阅，可切换至全站。快捷搜索保留搜索范围和高级筛选条件。 |
| 标签筛选 | 点按标签后在当前来源内打开独立工作区；返回后保留原页面的筛选与滚动位置。排行使用 E 站接口。 |
| 阅读 | 支持横向翻页、连续纵向滚动、双页布局和续读。iPhone / iPad 上的横向与纵向阅读均支持缩放。可导出应用已取得的图片文件；导出不另行下载站点原图。 |
| 下载与离线 | 支持队列、暂停与续传、分类、排序及批量操作。从「下载」导入图片文件夹、ZIP 或 CBZ；不支持加密、分卷或 ZIP64 压缩包。已完成的下载可打包为 ZIP 分享。 |
| 账号与收藏 | 支持访客浏览、网页登录、Cookie 导入、本地及云端收藏。已登录时显示可用的账号名称；自定义头像仅保存在本地。ExHentai 访问取决于站点权限。 |
| 安卓数据导入 | 在「我的 → 收藏」选择 Android EhViewer 导出的 SQLite 备份，可预览并单向导入本地收藏和阅读历史，不覆盖已有记录。不导入书签、阅读页码、下载文件或账号资料。 |
| 检查更新 | iPhone / iPad 查找 IPA；Mac 只查找 macOS 安装包。 |

## 从源码构建

建议使用 Xcode 27.1 或更新版本。iPhone Duo 的完整屏幕支持需要用 iOS 27.1 或更新的 SDK 构建，不影响 iOS 18.0 的最低安装要求。本地包的 Swift tools version 为 6.0。

```bash
git clone https://github.com/felixchaos/EhViewer-Apple.git
cd EhViewer-Apple
open "ehviewer apple.xcodeproj"
```

1. 等待 Swift Package 依赖解析，选择 `ehviewer apple` scheme。
2. 在 Mac 上运行时选择 **My Mac**。在 iPhone / iPad 上运行时，配置你自己的签名 Team 和唯一的 App Bundle ID；如果保留 Widget，扩展的签名和 Bundle ID 也需一并配置。
3. 选择目标设备，按 `⌘R`。使用真机时按 Xcode 和设备提示开启开发者模式并完成信任。

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

- [版本更新记录](https://github.com/felixchaos/EhViewer-Apple/releases) · [贡献指南](CONTRIBUTING.md) · [安全报告](SECURITY.md) · [Apache License 2.0](LICENSE)
- 致谢 [EhViewer](https://github.com/Ehviewer-Overhauled/Ehviewer)、[EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ) 与 [GRDB.swift](https://github.com/groue/GRDB.swift)。

内容来自第三方站点，本项目不托管内容。请遵守所在地法律法规及站点规则。
