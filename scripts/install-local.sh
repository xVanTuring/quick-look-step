#!/bin/bash
# scripts/install-local.sh
#
# 安装发布版 QuickLookStep.app 并注册 Quick Look 扩展；同时注销系统里其他位置的副本
# （编译目录、归档中间产物、旧版本等），保证 Finder 只用安装的这一份。
#
# 用法：
#   bash scripts/install-local.sh [--user] [QuickLookStep.app 或 .zip 的路径]
#
#   --user  安装到 ~/Applications（默认 /Applications）
#   不传路径时使用 scripts/release.sh 产出的 build/release/export/QuickLookStep.app
#
# 兼容 macOS 自带的 bash 3.2。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

APP_ID=tech.xvanturing.QuickLookStep
EXTENSION_IDS="$APP_ID.StepPreview $APP_ID.StepThumbnail"
# 1.6.1 及更早的版本沿用上游的 bundle id，安装新版时一并清理
LEGACY_APP_ID=com.johnboiles.QuickLookStep
LEGACY_EXTENSION_IDS="$LEGACY_APP_ID.StepPreview $LEGACY_APP_ID.StepThumbnail"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

DEST_DIR=/Applications
SRC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --user)    DEST_DIR="$HOME/Applications"; shift ;;
        -h|--help) sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         SRC=$1; shift ;;
    esac
done
SRC=${SRC:-$ROOT/build/release/export/QuickLookStep.app}
DEST="$DEST_DIR/QuickLookStep.app"

fail() {
    echo "错误：$*" >&2
    exit 1
}

# 传入 zip 时先解压到临时目录
TMP_DIR=""
cleanup() { [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT
case "$SRC" in
    *.zip)
        TMP_DIR=$(mktemp -d)
        ditto -x -k "$SRC" "$TMP_DIR"
        SRC="$TMP_DIR/QuickLookStep.app"
        ;;
esac

[ -d "$SRC" ] || fail "找不到 $SRC。先运行 scripts/release.sh，或者传入下载的 zip / App 路径。"
src_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")
[ "$src_id" = "$APP_ID" ] || fail "$SRC 的 bundle id 是 $src_id，不是 $APP_ID。"
codesign --verify --deep --strict "$SRC" || fail "$SRC 签名校验失败。"
if spctl -a -vv "$SRC" 2>&1 | grep -q 'source=Notarized Developer ID'; then
    echo "==> 来源：$SRC（已公证）"
else
    echo "==> 来源：$SRC（警告：未公证）"
fi

# ── 注销其他位置的副本 ───────────────────────────────────────────────
echo "==> 注销其他位置的副本"
unregister_app() {
    local app=$1 ext
    case "$app" in "$DEST") return 0 ;; esac
    for ext in "$app"/Contents/PlugIns/*.appex; do
        [ -d "$ext" ] && pluginkit -r "$ext" 2>/dev/null || true
    done
    "$LSREGISTER" -u "$app" 2>/dev/null || true
    echo "    已注销 $app"
}
# pluginkit 里登记的扩展（-A 所有版本，-D 包括重复项）
for id in $EXTENSION_IDS $LEGACY_EXTENSION_IDS; do
    pluginkit -m -A -D -v -i "$id" 2>/dev/null | awk -F'\t' 'NF >= 4 { print $NF }' | while IFS= read -r ext_path; do
        [ -n "$ext_path" ] || continue
        unregister_app "${ext_path%/Contents/PlugIns/*}"
    done
done
# LaunchServices 里登记的 App（UTI 声明来自这里）
"$LSREGISTER" -dump 2>/dev/null | sed -n -E 's/^path: +(.*\/QuickLookStep\.app)( \(0x[0-9a-f]+\))?$/\1/p' | sort -u | while IFS= read -r app_path; do
    unregister_app "$app_path"
done

# ── 安装 ───────────────────────────────────────────────────────────
echo "==> 安装到 $DEST"
mkdir -p "$DEST_DIR"
if [ -e "$DEST" ]; then
    old_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
    case "$old_id" in
        "$APP_ID"|"$LEGACY_APP_ID") ;;
        *) fail "$DEST 已存在，但 bundle id 是「$old_id」，不是本项目的 App，不覆盖。" ;;
    esac
    # 旧版就装在目标位置时，上面的清理会跳过它，这里补上注销
    if [ "$old_id" = "$LEGACY_APP_ID" ]; then
        pluginkit -r "$DEST"/Contents/PlugIns/*.appex 2>/dev/null || true
        "$LSREGISTER" -u "$DEST" 2>/dev/null || true
        # 同一路径换了 bundle id，正在运行的 Finder 仍按旧 id 缓存扩展的服务名，
        # 空格预览会报 "Extension ... not found"，装完要重启 Finder
        RESTART_FINDER=true
    fi
    rm -rf "$DEST"
fi
ditto "$SRC" "$DEST"

echo "==> 注册扩展并重置 Quick Look 缓存"
"$LSREGISTER" -f -R "$DEST"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
killall QuickLookUIService 2>/dev/null || true

# pluginkit 是异步登记的，刚注销同类扩展时新登记可能被吞掉，逐个检查并重试
for id in $EXTENSION_IDS; do
    ext="$DEST/Contents/PlugIns/${id##*.}.appex"
    registered=false
    for _ in 1 2 3 4 5; do
        pluginkit -a "$ext" 2>/dev/null || true
        sleep 1
        if pluginkit -m -A -D -v -i "$id" 2>/dev/null | grep -qF "$ext"; then
            registered=true
            break
        fi
    done
    [ "$registered" = true ] || fail "$id 登记失败，可以重新运行本脚本，或者注销后重新登录再试。"
    pluginkit -e use -i "$id"
done

if [ "${RESTART_FINDER:-false}" = true ]; then
    echo "==> 替换了旧包名的版本，重启 Finder 以清除它缓存的旧扩展信息"
    killall Finder 2>/dev/null || true
fi

echo "==> 当前登记的扩展"
for id in $EXTENSION_IDS $LEGACY_EXTENSION_IDS; do
    pluginkit -m -A -D -v -i "$id" 2>/dev/null | grep -v 'plug-in' || true
done
echo "完成。在 Finder 里选中 .step / .stp 文件按空格即可预览。"
