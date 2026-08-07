#!/bin/zsh
# 构建、Developer ID 签名、公证、装订并制作 GitHub Release 资产。
#
# 用法：
#   PREPARE_SIGN_IDENTITY="Apple Distribution: … (TEAMID)" \
#   TEAM_ID="TEAMID" \
#   ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8" \
#   ASC_KEY_ID="XXXXXXXXXX" \
#   ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000" \
#   ./gui/release-github.sh 1.1.0

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO="${SCRIPT_DIR:A:h}"
VERSION="${1:-}"
APP_NAME="Quaderno Converter"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
DIST_DIR="$REPO/dist"
ARCHIVE="$DIST_DIR/Quaderno-Converter-${VERSION}-macOS-arm64.zip"
CHECKSUM="$ARCHIVE.sha256"
PREPARE_SIGN_IDENTITY="${PREPARE_SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" && "$WORK_DIR" == /tmp/quaderno-release.* && -d "$WORK_DIR" ]]; then
    rm -R -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || { print -u2 "用法: $0 <major.minor.patch>"; exit 2; }
[[ -n "$PREPARE_SIGN_IDENTITY" ]] \
  || { print -u2 "缺少 PREPARE_SIGN_IDENTITY（必须是本机 Apple Distribution 证书）"; exit 2; }
[[ "$PREPARE_SIGN_IDENTITY" == Apple\ Distribution:* ]] \
  || { print -u2 "PREPARE_SIGN_IDENTITY 不是 Apple Distribution 证书"; exit 2; }
[[ "$TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] \
  || { print -u2 "TEAM_ID 必须是 10 位 Apple Developer Team ID"; exit 2; }
[[ -f "$ASC_KEY_PATH" ]] \
  || { print -u2 "ASC_KEY_PATH 不是可读的 App Store Connect API 私钥"; exit 2; }
[[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]] \
  || { print -u2 "缺少 ASC_KEY_ID 或 ASC_ISSUER_ID"; exit 2; }

security find-identity -v -p codesigning | grep -Fq "\"$PREPARE_SIGN_IDENTITY\"" \
  || { print -u2 "钥匙串中没有可用的签名身份：$PREPARE_SIGN_IDENTITY"; exit 2; }

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SCRIPT_DIR/mac/Info.plist")
bundle_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$SCRIPT_DIR/mac/Info.plist")
[[ "$bundle_version" == "$VERSION" ]] \
  || { print -u2 "Info.plist 版本为 $bundle_version，与发布版本 $VERSION 不一致"; exit 2; }

mkdir -p "$DIST_DIR"
[[ ! -e "$ARCHIVE" && ! -e "$CHECKSUM" ]] \
  || { print -u2 "发行文件已存在，请先确认后手动移走：$ARCHIVE"; exit 2; }

print ">>> 构建 Hardened Runtime 预签名 App"
SIGN_IDENTITY="$PREPARE_SIGN_IDENTITY" "$SCRIPT_DIR/build-app.sh"

# Xcode 的 developer-id 导出可以使用已登录 Account Holder 的云管理证书，
# 因而不必在构建机上长期保存 Developer ID 私钥。导出会保留预签名中的
# Hardened Runtime 标志，并把主程序、pandoc、typst 与 libgmp 全部重签。
WORK_DIR=$(mktemp -d /tmp/quaderno-release.XXXXXX)
ARCHIVE_DIR="$WORK_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
ARCHIVE_INFO="$ARCHIVE_DIR/Info.plist"
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"

mkdir -p "$ARCHIVE_DIR/Products/Applications"
ditto "$APP_DIR" "$ARCHIVE_DIR/Products/Applications/$APP_NAME.app"

plutil -create xml1 "$ARCHIVE_INFO"
plutil -insert ArchiveVersion -integer 2 "$ARCHIVE_INFO"
plutil -insert CreationDate -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ARCHIVE_INFO"
plutil -insert Name -string "$APP_NAME" "$ARCHIVE_INFO"
plutil -insert SchemeName -string "$APP_NAME" "$ARCHIVE_INFO"
plutil -insert ApplicationProperties -dictionary "$ARCHIVE_INFO"
plutil -insert ApplicationProperties.ApplicationPath -string "Applications/$APP_NAME.app" "$ARCHIVE_INFO"
plutil -insert ApplicationProperties.CFBundleIdentifier -string "com.eink-truescale.gui" "$ARCHIVE_INFO"
plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$VERSION" "$ARCHIVE_INFO"
plutil -insert ApplicationProperties.CFBundleVersion -string "$bundle_build" "$ARCHIVE_INFO"
plutil -insert ApplicationProperties.SigningIdentity -string "$PREPARE_SIGN_IDENTITY" "$ARCHIVE_INFO"

plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert destination -string export "$EXPORT_OPTIONS"
plutil -insert method -string developer-id "$EXPORT_OPTIONS"
plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"

print ">>> Xcode 云端 Developer ID 签名"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_DIR" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

rm -R -- "$APP_DIR"
ditto "$EXPORT_DIR/$APP_NAME.app" "$APP_DIR"

print ">>> 验证 Developer ID 与 Hardened Runtime"
for f in \
  "$APP_DIR" \
  "$APP_DIR/Contents/Resources/bin/pandoc" \
  "$APP_DIR/Contents/Resources/bin/typst" \
  "$APP_DIR/Contents/Resources/lib/libgmp.10.dylib"; do
  signature=$(codesign -dv --verbose=4 "$f" 2>&1)
  print -r -- "$signature" | grep -Fq 'Authority=Developer ID Application:' \
    || { print -u2 "不是 Developer ID Application 签名：$f"; exit 1; }
  print -r -- "$signature" | grep -Fq 'flags=0x10000(runtime)' \
    || { print -u2 "缺少 Hardened Runtime：$f"; exit 1; }
done
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

print ">>> 制作公证提交包"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

print ">>> 提交 Apple 公证并等待结果"
xcrun notarytool submit "$ARCHIVE" \
  --key "$ASC_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait

print ">>> 装订公证票据"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

# 公证票据会改变 app bundle，必须在装订后重新制作最终下载包。
rm "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
(cd "$DIST_DIR" && shasum -a 256 "${ARCHIVE:t}" > "${CHECKSUM:t}")

print ">>> 最终分发验证"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl --assess --type execute --verbose=4 "$APP_DIR"

print ">>> 完成"
print "    $ARCHIVE"
print "    $CHECKSUM"
