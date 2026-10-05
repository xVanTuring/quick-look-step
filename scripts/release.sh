#!/bin/bash
# scripts/release.sh
#
# 改版本号 → 归档 → 按 Developer ID 导出 → 公证 → 装订票据 → 提交并打 tag → 发布 GitHub Release
#
# 用法：
#   bash scripts/release.sh <version> [--notes-file <path>]
#   bash scripts/release.sh --dry-run
#
#   <version>          CFBundleShortVersionString，例如 1.6.1；build 号自动加 1
#   --notes-file PATH  用这个文件的内容作为 Release 说明（默认自动生成）
#   --dry-run          只归档、导出并校验签名，不改版本号、不公证、不提交、不发布，
#                      用来检查本机打包环境
#
# 本机前置条件：
#   - 钥匙串里有 "Developer ID Application" 证书（团队 T8F5T6HKG8）
#   - notarytool 的钥匙串配置（默认 noticky-notary，可用 NOTARY_PROFILE 覆盖），没有的话先建：
#       xcrun notarytool store-credentials noticky-notary --apple-id <Apple ID> --team-id T8F5T6HKG8
#   - gh 已登录，且对 GH_REPO 有写权限
#
# 兼容 macOS 自带的 bash 3.2。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"

TEAM_ID=${TEAM_ID:-T8F5T6HKG8}
NOTARY_PROFILE=${NOTARY_PROFILE:-noticky-notary}
GH_REPO=${GH_REPO:-xVanTuring/quick-look-step}

PROJECT=QuickLookStep/QuickLookStep.xcodeproj
PBXPROJ=$PROJECT/project.pbxproj
SCHEME=QuickLookStep
PRODUCT=QuickLookStep
OUT=build/release
ARCHIVE=$OUT/$PRODUCT.xcarchive
EXPORT_DIR=$OUT/export
DIST_DIR=$OUT/dist
APP=$EXPORT_DIR/$PRODUCT.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

usage() {
    sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

VERSION=""
NOTES_FILE=""
DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file) NOTES_FILE="${2:?--notes-file 需要一个文件路径}"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        -*)           echo "未知参数：$1" >&2; usage ;;
        *)
            if [ -z "$VERSION" ]; then VERSION=$1; shift
            else echo "多余的参数：$1" >&2; usage; fi ;;
    esac
done

fail() {
    echo "错误：$*" >&2
    exit 1
}

# 归档和导出时 Xcode 会把产物里的 App 注册进 LaunchServices。
# 这些中间产物不应该被 Finder 拿来用，打包结束后全部注销。
unregister_build_products() {
    local app ext
    [ -d "$OUT" ] || return 0
    find "$OUT" -type d -name "$PRODUCT.app" -prune -print | while IFS= read -r app; do
        for ext in "$app"/Contents/PlugIns/*.appex; do
            [ -d "$ext" ] && pluginkit -r "$ext" 2>/dev/null || true
        done
        "$LSREGISTER" -u "$app" 2>/dev/null || true
    done
}

# ── 预检 ────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
    [ -n "$VERSION" ] || usage
    echo "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' || fail "版本号格式不对：$VERSION（例：1.6.1）"
    TAG="release/v$VERSION"

    if ! git diff --quiet || ! git diff --cached --quiet; then
        git status --short >&2
        fail "工作区有未提交的改动，先提交或暂存。"
    fi
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "只能在 main 分支上发布。"
    ! git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null || fail "本地已经有 tag $TAG。"
    ! git ls-remote --tags origin "$TAG" | grep -q "refs/tags/$TAG$" || fail "origin 上已经有 tag $TAG。"
    [ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || fail "找不到 --notes-file：$NOTES_FILE"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool 配置 $NOTARY_PROFILE 不存在或无效，见脚本开头的说明。"
    gh repo view "$GH_REPO" >/dev/null 2>&1 || fail "gh 无法访问 $GH_REPO，先运行 gh auth login。"
fi
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
    || fail "钥匙串里找不到团队 $TEAM_ID 的 Developer ID Application 证书。"

# ── 改版本号（失败时提示还原）────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
    current_version=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/')
    current_build=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);.*/\1/')
    next_build=$((current_build + 1))
    echo "==> 版本号 $current_version (build $current_build) → $VERSION (build $next_build)"
    sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/" "$PBXPROJ"
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $next_build;/" "$PBXPROJ"
    trap 'if [ $? -ne 0 ]; then echo "发布中断。还原版本号：git checkout -- $PBXPROJ" >&2; fi' EXIT
fi

# ── 归档 + Developer ID 导出 ─────────────────────────────────────────
echo "==> 清理 $OUT"
unregister_build_products
rm -rf "$OUT"
mkdir -p "$DIST_DIR"

echo "==> 归档 Release"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$OUT/DerivedData" \
    -archivePath "$ARCHIVE" \
    -quiet \
    archive
[ -d "$ARCHIVE" ] || fail "没有生成归档：$ARCHIVE"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST

echo "==> 按 Developer ID 导出"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -quiet
[ -d "$APP" ] || fail "导出的 App 不存在：$APP"

echo "==> 校验签名"
codesign --verify --deep --strict "$APP"
for bundle in "$APP" "$APP"/Contents/PlugIns/*.appex; do
    info=$(codesign -dv "$bundle" 2>&1)
    echo "$info" | grep -q "TeamIdentifier=$TEAM_ID" || fail "$bundle 的团队不是 $TEAM_ID"
    echo "$info" | grep -q 'flags=.*runtime' || fail "$bundle 没有启用 hardened runtime"
    echo "    $(basename "$bundle")  $(echo "$info" | grep -E '^Identifier=')"
done

if [ "$DRY_RUN" = true ]; then
    unregister_build_products
    echo "==> [dry-run] 签名正常，产物在 $APP（未公证）"
    exit 0
fi

# ── 公证 + 装订票据 ─────────────────────────────────────────────────
NOTARY_ZIP=$OUT/notarize.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
echo "==> 提交公证（会等待结果，通常几分钟）"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$OUT/notary.log" || true
if ! grep -q 'status: Accepted' "$OUT/notary.log"; then
    submission=$(grep -m1 -E '^ *id: ' "$OUT/notary.log" | awk '{print $2}')
    [ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "公证没有通过，详情见上面的日志。"
fi

echo "==> 装订公证票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP" 2>&1 | grep -q 'source=Notarized Developer ID' || fail "Gatekeeper 校验没有通过"

ZIP=$DIST_DIR/$PRODUCT-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "==> $ZIP"
echo "    SHA-256 $SHA"

# ── 提交、打 tag、推送 ───────────────────────────────────────────────
trap - EXIT
echo "==> 提交版本号并打 tag $TAG"
git add "$PBXPROJ"
git commit -q -m "release: $VERSION (build $next_build)"
git tag -a "$TAG" -m "QuickLookStep $VERSION"
git push -q origin main
git push -q origin "$TAG"

# ── 发布 GitHub Release ─────────────────────────────────────────────
if [ -z "$NOTES_FILE" ]; then
    NOTES_FILE=$OUT/release-notes.md
    cat > "$NOTES_FILE" <<NOTES
QuickLookStep $VERSION (build $next_build), signed with Developer ID ($TEAM_ID) and notarized by Apple.

Quick Look preview and Finder thumbnails for STEP (\`.step\` / \`.stp\`) files.

Install: unzip, move \`QuickLookStep.app\` to \`/Applications\`, then open it once to register the extensions.

SHA-256 for \`$(basename "$ZIP")\`:
\`$SHA\`
NOTES
fi
echo "==> 发布 GitHub Release（$GH_REPO）"
gh release create "$TAG" -R "$GH_REPO" --title "QuickLookStep $VERSION" --notes-file "$NOTES_FILE" "$ZIP"

unregister_build_products
echo "==> 完成。安装到本机：bash scripts/install-local.sh"
