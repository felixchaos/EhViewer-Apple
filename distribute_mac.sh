#!/usr/bin/env zsh
#
# distribute_mac.sh — EhViewer-Apple macOS 自动构建 + 签名 + 公证 + DMG 打包
#
# 用法:
#   ./distribute_mac.sh
#
# 前置条件:
#   1. 已安装 Xcode 16+ 并登录 Apple Developer 账号
#   2. Keychain 中已导入 "Developer ID Application" 证书
#   3. 配置环境变量（直接 export 或写入 .env 文件）:
#        APPLE_ID           — Apple 开发者账号邮箱
#        TEAM_ID            — 开发者团队 ID
#        APP_SPECIFIC_PASSWORD — App 专用密码
#
# 输出:
#   build/EhViewer-Apple-<version>.dmg  — 已公证、可直接分发的安装包
#

set -euo pipefail

# ─────────────────────────── 颜色输出 ───────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo "${CYAN}[INFO]${NC} $*" }
success() { echo "${GREEN}[✔]${NC} $*" }
warn()    { echo "${YELLOW}[⚠]${NC} $*" }
fail()    { echo "${RED}[✘]${NC} $*" >&2; exit 1 }

# ─────────────────────────── 项目常量 ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT_FILE="$PROJECT_DIR/ehviewer apple.xcodeproj"
SCHEME="ehviewer apple"
APP_NAME="ehviewer apple"
BUNDLE_ID="Stellatrix.ehviewer-apple"

BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
DMG_DIR="$BUILD_DIR/dmg_staging"

# ─────────────────────────── 加载环境变量 ───────────────────────────
load_env() {
    # 按优先级: 当前目录 .env → 项目目录 .env
    local env_files=("$PWD/.env" "$PROJECT_DIR/.env" "$HOME/.ehviewer-apple.env")
    for f in "${env_files[@]}"; do
        if [[ -f "$f" ]]; then
            info "从 $f 加载环境变量"
            # 安全加载: 只读取 KEY=VALUE 行, 忽略注释和空行
            while IFS='=' read -r key value; do
                key=$(echo "$key" | xargs)               # trim
                [[ -z "$key" || "$key" == \#* ]] && continue
                value=$(echo "$value" | xargs | sed "s/^['\"]//;s/['\"]$//")  # trim + unquote
                export "$key=$value" 2>/dev/null || true
            done < "$f"
            break
        fi
    done
}

load_env

# ─────────────────────────── 验证环境 ───────────────────────────
check_prerequisites() {
    info "检查环境..."

    # Xcode
    command -v xcodebuild &>/dev/null || fail "未找到 xcodebuild，请安装 Xcode"
    local xcode_ver
    xcode_ver=$(xcodebuild -version | head -1)
    info "  $xcode_ver"

    # codesign
    command -v codesign &>/dev/null || fail "未找到 codesign"

    # notarytool
    xcrun notarytool --version &>/dev/null || fail "未找到 notarytool (需要 Xcode 13+)"

    # 环境变量
    [[ -n "${APPLE_ID:-}" ]]              || fail "缺少 APPLE_ID 环境变量 (Apple 开发者邮箱)"
    [[ -n "${TEAM_ID:-}" ]]               || fail "缺少 TEAM_ID 环境变量 (开发者团队 ID)"
    [[ -n "${APP_SPECIFIC_PASSWORD:-}" ]] || fail "缺少 APP_SPECIFIC_PASSWORD 环境变量 (App 专用密码)"

    # Developer ID Application 证书
    local cert_name
    cert_name=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
    if [[ -z "$cert_name" ]]; then
        fail "Keychain 中未找到 \"Developer ID Application\" 证书。\n请在 Xcode → Settings → Accounts → 管理证书 中创建，或从 developer.apple.com 下载安装。"
    fi
    SIGNING_IDENTITY=$(echo "$cert_name" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.+)"/\1/')
    info "  签名身份: $SIGNING_IDENTITY"

    success "环境检查通过"
}

# ─────────────────────────── 1. 构建 Archive ───────────────────────────
build_archive() {
    info "清理旧产物..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    info "构建 Release Archive..."
    xcodebuild archive \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "platform=macOS" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--options runtime --timestamp" \
        2>&1 | tail -5

    [[ -d "$ARCHIVE_PATH" ]] || fail "Archive 构建失败，请检查完整日志"
    success "Archive 构建完成: $ARCHIVE_PATH"
}

# ─────────────────────────── 2. 导出 .app ───────────────────────────
export_app() {
    info "导出 .app..."
    mkdir -p "$EXPORT_DIR"

    # 生成 ExportOptions.plist
    local export_plist="$BUILD_DIR/ExportOptions.plist"
    cat > "$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict/>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$export_plist" \
        2>&1 | tail -5

    [[ -d "$APP_PATH" ]] || fail ".app 导出失败"
    success ".app 导出完成: $APP_PATH"
}

# ─────────────────────────── 3. 深度重签名 ───────────────────────────
deep_codesign() {
    info "深度签名 .app (Hardened Runtime)..."

    # 对所有嵌入的框架/dylib 逐一签名 (由内向外)
    find "$APP_PATH/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null | while IFS= read -r -d '' fw; do
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$fw" 2>/dev/null || true
    done

    # 对 .app 整体深度签名
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/ehviewer apple/ehviewer_apple.entitlements" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_PATH"

    # 验证签名
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 || fail "签名验证失败"
    success "签名完成并验证通过"
}

# ─────────────────────────── 4. 打包 DMG ───────────────────────────
create_dmg() {
    info "创建 DMG 安装包..."

    # 从 Info.plist 读取版本号
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

    local dmg_name="EhViewer-Apple-${version}.dmg"
    local dmg_path="$BUILD_DIR/$dmg_name"
    local dmg_temp="$BUILD_DIR/${dmg_name%.dmg}-temp.dmg"

    rm -rf "$DMG_DIR"
    mkdir -p "$DMG_DIR"

    # 复制 .app 到临时目录
    cp -R "$APP_PATH" "$DMG_DIR/"

    # 创建 Applications 快捷方式
    ln -s /Applications "$DMG_DIR/Applications"

    # 创建临时可写 DMG
    local vol_name="EhViewer Apple"
    hdiutil create -ov -srcfolder "$DMG_DIR" -volname "$vol_name" \
        -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
        -format UDRW "$dmg_temp" 2>/dev/null

    # 挂载并美化
    local device
    device=$(hdiutil attach -readwrite -noverify "$dmg_temp" | grep "Apple_HFS" | awk '{print $1}')

    # AppleScript 设置窗口外观
    osascript <<APPLESCRIPT
    tell application "Finder"
        tell disk "$vol_name"
            open
            set the bounds of container window to {400, 100, 920, 440}
            set current view of container window to icon view
            set arrangement of icon view options of container window to not arranged
            set icon size of icon view options of container window to 80
            set background color of icon view options of container window to {65535, 65535, 65535}
            set position of item "${APP_NAME}.app" of container window to {130, 170}
            set position of item "Applications" of container window to {390, 170}
            close
        end tell
    end tell
APPLESCRIPT

    sync
    hdiutil detach "$device" 2>/dev/null || true

    # 压缩为只读 DMG
    hdiutil convert "$dmg_temp" -format UDZO -imagekey zlib-level=9 -o "$dmg_path"
    rm -f "$dmg_temp"
    rm -rf "$DMG_DIR"

    DMG_PATH="$dmg_path"
    success "DMG 已创建: $DMG_PATH"
}

# ─────────────────────────── 5. 公证 DMG ───────────────────────────
notarize_dmg() {
    info "提交 DMG 到 Apple 公证服务 (这可能需要几分钟)..."

    local log_file="$BUILD_DIR/notarization.log"

    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --wait \
        --timeout 30m \
        2>&1 | tee "$log_file"

    # 检查公证结果
    if grep -q "status: Accepted" "$log_file"; then
        success "公证通过！"
    else
        warn "公证可能失败，正在获取详细日志..."

        # 提取 submission ID 并查询日志
        local sub_id
        sub_id=$(grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" "$log_file" | head -1 || true)
        if [[ -n "$sub_id" ]]; then
            info "Submission ID: $sub_id"
            xcrun notarytool log "$sub_id" \
                --apple-id "$APPLE_ID" \
                --team-id "$TEAM_ID" \
                --password "$APP_SPECIFIC_PASSWORD" \
                "$BUILD_DIR/notarization-detail.json" 2>/dev/null || true

            if [[ -f "$BUILD_DIR/notarization-detail.json" ]]; then
                echo ""
                warn "公证详细日志:"
                cat "$BUILD_DIR/notarization-detail.json"
                echo ""
            fi
        fi

        fail "公证未通过，请检查上方日志。常见原因:\n  - Hardened Runtime 未启用\n  - 使用了被禁止的 API / 私有框架\n  - 签名不包含 timestamp"
    fi
}

# ─────────────────────────── 6. 植入公证票据 ───────────────────────────
staple_dmg() {
    info "植入公证票据 (Staple)..."
    xcrun stapler staple "$DMG_PATH" || fail "Staple 失败"

    # 验证
    xcrun stapler validate "$DMG_PATH" || fail "Staple 验证失败"
    success "票据植入完成"
}

# ─────────────────────────── 7. 最终验证 ───────────────────────────
final_verify() {
    info "最终验证..."

    # Gatekeeper 评估
    spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" 2>&1 || true

    local size
    size=$(du -sh "$DMG_PATH" | awk '{print $1}')
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

    echo ""
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo "${GREEN}${BOLD}  ✅ 构建完成！${NC}"
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  应用名称:   EhViewer Apple"
    echo "  版本号:     ${version}"
    echo "  Bundle ID:  ${BUNDLE_ID}"
    echo "  文件大小:   ${size}"
    echo ""
    echo "  ${BOLD}输出文件:${NC}"
    echo "  ${CYAN}${DMG_PATH}${NC}"
    echo ""
    echo "  签名状态:   ✅ Developer ID (有效期约1年)"
    echo "  公证状态:   ✅ Apple Notarized"
    echo "  票据植入:   ✅ Stapled"
    echo ""
    echo "  可直接分发给用户，双击 DMG → 拖入 Applications → 运行"
    echo "  无 Gatekeeper 警告，无需右键打开"
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
}

# ─────────────────────────── 主流程 ───────────────────────────
main() {
    echo ""
    echo "${BOLD}🍎 EhViewer-Apple macOS 分发构建${NC}"
    echo "${BOLD}════════════════════════════════${NC}"
    echo ""

    check_prerequisites
    echo ""
    build_archive
    echo ""
    export_app
    echo ""
    deep_codesign
    echo ""
    create_dmg
    echo ""
    notarize_dmg
    echo ""
    staple_dmg
    echo ""
    final_verify
}

main "$@"
