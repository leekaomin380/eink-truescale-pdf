#!/bin/zsh
# gui/build-app.sh — 编译 Swift 外壳并组装 .app bundle
# 用法: ./gui/build-app.sh
# 产出: gui/Quaderno Converter.app

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO="${SCRIPT_DIR:A:h}"
MAC_DIR="$SCRIPT_DIR/mac"
APP_NAME="Quaderno Converter"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"

echo ">>> 清理旧 .app"
rm -rf "$APP_DIR"

echo ">>> 编译 AppShell.swift"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

swiftc "$MAC_DIR/AppShell.swift" \
    -o "$APP_DIR/Contents/MacOS/AppShell" \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos14.0

echo ">>> 复制 Info.plist"
cp "$MAC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

ICON_SRC="$MAC_DIR/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    echo ">>> 复制图标"
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo ">>> 完成: $APP_DIR"
echo "    双击访达中的 \"$APP_NAME.app\" 即可启动"
