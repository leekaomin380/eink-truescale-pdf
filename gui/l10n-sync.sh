#!/bin/zsh
# 从 Swift 源码提取全部可本地化文案，合并进 String Catalog（保留已有译文，新增条目待翻译）。
# 改了界面文案后运行一次，再补齐 Localizable.xcstrings 中 en / ja 的译文。需要完整 Xcode（xcstringstool）。
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
MAC_DIR="$SCRIPT_DIR/mac"
CATALOG="$MAC_DIR/Localization/Localizable.xcstrings"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SDK_ARGS=()
if [[ ! -f "$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
  for cand in MacOSX26.sdk MacOSX26.5.sdk MacOSX15.2.sdk; do
    [[ -d "/Library/Developer/CommandLineTools/SDKs/$cand" ]] && { SDK_ARGS=(-sdk "/Library/Developer/CommandLineTools/SDKs/$cand"); break; }
  done
fi

swiftc "${SDK_ARGS[@]}" -target arm64-apple-macos14.0 -parse-as-library \
  -emit-localized-strings -emit-localized-strings-path "$WORK" \
  -c "$MAC_DIR"/*.swift "$MAC_DIR"/wechat/*.swift -module-name QuadernoConverter -o "$WORK/unused.o" \
  -wmo 2>&1 | grep -E "error" || true
[[ -f "$CATALOG" ]] || print -r -- '{"sourceLanguage":"zh-Hans","strings":{},"version":"1.0"}' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/*.stringsdata
print -r -- "已同步：$CATALOG"
