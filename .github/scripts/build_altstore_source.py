#!/usr/bin/env python3
"""
从 GitHub Releases 生成 AltStore / SideStore 的源清单 (source.json)。

背景：iOS 不允许下载并执行原生代码（内核层强制代码签名），所以这个 App
没有真正的热更新。能做到「装一次之后自动更新」的是 AltStore / SideStore 的
源订阅——用户添加一次源，之后新版本会出现在它们的更新列表里，
用用户自己的证书重签安装，不需要再来 GitHub 手动下载。

这个脚本在每次发布后重新生成清单，把全部历史版本都列进去：
AltStore 需要看到完整的 versions 数组才能判断「有没有比本机更新的版本」，
只放最新一条会让降级和跳版判断失效。
"""

import json
import os
import sys
import urllib.request

REPO = "felixchaos/EhViewer-Apple"
BUNDLE_ID = "Stellatrix.ehviewer-apple"


def fetch_releases():
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/releases?per_page=100",
        headers={"Accept": "application/vnd.github+json"},
    )
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def build_versions(releases):
    versions = []
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        ipa = next(
            (a for a in rel.get("assets", []) if a["name"].endswith(".ipa")), None
        )
        if not ipa:
            # 只有 macOS DMG 的发布跳过——AltStore 只认 ipa
            continue
        tag = rel["tag_name"]
        versions.append(
            {
                "version": tag[1:] if tag.startswith("v") else tag,
                "date": rel["published_at"],
                "localizedDescription": (rel.get("body") or "").strip()[:2000],
                "downloadURL": ipa["browser_download_url"],
                "size": ipa["size"],
                "minOSVersion": "26.2",
            }
        )
    return versions


def main():
    releases = fetch_releases()
    versions = build_versions(releases)
    if not versions:
        print("没有找到带 .ipa 的正式发布，不生成清单", file=sys.stderr)
        return 1

    source = {
        "name": "EhViewer-Apple",
        "identifier": "icu.stellatrix.ehviewer",
        "sourceURL": f"https://raw.githubusercontent.com/{REPO}/main/source.json",
        "website": f"https://github.com/{REPO}",
        "apps": [
            {
                "name": "EhViewer",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": "Felix Chaos",
                "subtitle": "E-Hentai / ExHentai 画廊客户端",
                "localizedDescription": (
                    "用 SwiftUI 重写的 E-Hentai / ExHentai 画廊客户端，"
                    "支持 iPhone、iPad 与 Mac。功能与交互对齐 Android 端的 "
                    "EhViewer_CN_SXJ。"
                ),
                "iconURL": (
                    f"https://raw.githubusercontent.com/{REPO}/main/"
                    "ehviewer%20apple/Assets.xcassets/AppLogo.imageset/AppLogo.png"
                ),
                "tintColor": "FFB340",
                "category": "entertainment",
                "versions": versions,
            }
        ],
        "news": [],
    }

    with open("source.json", "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"已生成 source.json，含 {len(versions)} 个版本")
    return 0


if __name__ == "__main__":
    sys.exit(main())
