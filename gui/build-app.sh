#!/bin/zsh
# gui/build-app.sh — 编译原生 SwiftUI 应用并组装 .app bundle
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

echo ">>> 编译原生 SwiftUI 应用"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

swiftc \
    "$MAC_DIR/QuadernoApp.swift" \
    "$MAC_DIR/ContentView.swift" \
    "$MAC_DIR/ConversionViewModel.swift" \
    "$MAC_DIR/wechat/WeChatExtractor.swift" \
    "$MAC_DIR/wechat/ImageInliner.swift" \
    "$MAC_DIR/wechat/LocalExtraction.swift" \
    -o "$APP_DIR/Contents/MacOS/QuadernoConverter" \
    -framework SwiftUI \
    -framework AppKit \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework WebKit \
    -framework CoreImage \
    -target arm64-apple-macos14.0

echo ">>> 复制 Info.plist"
cp "$MAC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

ICON_SRC="$MAC_DIR/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    echo ">>> 复制图标"
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo ">>> 复制 JS 抽取器"
cp "$MAC_DIR/wechat/wechat_extractor.js" "$APP_DIR/Contents/Resources/wechat_extractor.js"

echo ">>> 复制运行时依赖"
cp "$REPO/config.sh" "$APP_DIR/Contents/Resources/config.sh"
cp "$REPO/devices.json" "$APP_DIR/Contents/Resources/devices.json"
cp "$REPO/book.sh" "$APP_DIR/Contents/Resources/book.sh"
chmod +x "$APP_DIR/Contents/Resources/book.sh"
cp "$REPO/deliver.typ" "$APP_DIR/Contents/Resources/deliver.typ"
cp "$REPO/book-filter.lua" "$APP_DIR/Contents/Resources/book-filter.lua"

# ---------------------------------------------------------------------------
# 打包渲染引擎，使 .app 在【没有 Homebrew】的机器上也能工作。
#
# 【为什么必须做】此前 app 只是个界面：装上后能打开、能选文件，一点转换就报
# 「未找到 pandoc → brew install pandoc」。对不用命令行的人这就是终点，
# 「装上就能用」根本不成立。
#
# 【为什么只有这两个】poppler 曾被 pdfinfo 用于读页面尺寸，它需要成串动态库
# （libpoppler / liblcms2 / freetype / fontconfig…），重定位成本远高于收益；
# 已改用 PDFKit 原生实现，该依赖整棵树被消除。calibre（mobi 转换）是完整 app、
# 数百 MB，仍作为可选外部依赖，不打包。
#
# 【体积】pandoc 约 263MB（已 strip，压不动）+ typst 约 43MB。这是达成
# 「零配置」的代价，是有意接受的取舍。
# ---------------------------------------------------------------------------
echo ">>> 打包渲染引擎（pandoc / typst）"
BIN_DIR="$APP_DIR/Contents/Resources/bin"
LIB_DIR="$APP_DIR/Contents/Resources/lib"
mkdir -p "$BIN_DIR" "$LIB_DIR"

for tool in pandoc typst; do
  src=$(command -v "$tool" 2>/dev/null) || true
  [[ -n "$src" ]] || { echo "!!! 未找到 $tool，无法打包 —— 构建机需先 brew install $tool"; exit 1; }
  src=$(readlink -f "$src")
  arch=$(lipo -archs "$src" 2>/dev/null)
  echo "    $tool ($arch, $(du -h "$src" | cut -f1))"
  cp "$src" "$BIN_DIR/$tool"
  chmod +x "$BIN_DIR/$tool"
done

# pandoc 链接 Homebrew 的 libgmp，且是【绝对路径】硬编码在二进制里。
# 不重定位的话，目标机没有 /opt/homebrew/opt/gmp/... 就直接崩，
# 而且是启动即崩、错误信息晦涩（dyld: Library not loaded）。
# 故：把 dylib 一并拷入 Resources/lib，并把引用改写为 @executable_path 相对路径。
echo ">>> 重定位动态库引用"
# 递归处理：一个 dylib 自己可能又依赖别的 Homebrew dylib。
# 【易漏的一点】dylib 自身的 install ID（otool -L 输出的第一行）也是绝对路径，
# 必须用 -id 一并改写；只改 -change 会留下引用，自检当场抓到过。
relocate() {  # $1 = 待处理的 Mach-O 文件
  local f="$1" dep dylib
  otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
      | grep -E '^/opt/homebrew/|^/usr/local/' | sort -u | while read -r dep; do
    dylib=$(basename "$dep")
    if [[ ! -f "$LIB_DIR/$dylib" ]]; then
      cp "$(readlink -f "$dep")" "$LIB_DIR/$dylib"
      chmod u+w "$LIB_DIR/$dylib"
      # 先把新拷入的 dylib 的自身 ID 改成相对路径，再递归处理它的依赖
      install_name_tool -id "@executable_path/../lib/$dylib" "$LIB_DIR/$dylib" 2>/dev/null
      echo "    + $dylib"
      relocate "$LIB_DIR/$dylib"
    fi
    install_name_tool -change "$dep" "@executable_path/../lib/$dylib" "$f" 2>/dev/null
  done
  return 0
}

for bin in "$BIN_DIR"/*; do
  [[ -f "$bin" ]] && relocate "$bin"
done

# 签名身份。默认 `-` 即 ad-hoc；有 Developer ID 后可传入而无需改脚本：
#   SIGN_IDENTITY="Developer ID Application: …" ./gui/build-app.sh
# 注意 ad-hoc 只够本机运行 —— Apple 的 syspolicy_check 明确判定
# 「adhoc signed apps are not suitable for distribution」，公证另需 notarytool。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # ad-hoc 是本地开发模式；不给它强开 Hardened Runtime，否则无 Team ID 的
  # pandoc 与 libgmp 会触发库验证，反而破坏「本机构建可运行」。
  SIGN_FLAGS=()
else
  # Developer ID 站外分发必须启用 Hardened Runtime；安全时间戳由 Apple
  # 时间戳服务签发，是后续公证与 Gatekeeper 验证的必要组成。
  SIGN_FLAGS=(--options runtime --timestamp)
fi

echo ">>> 重签渲染引擎"
for f in "$BIN_DIR"/* "$LIB_DIR"/*; do
  [[ -f "$f" ]] || continue
  codesign -f "${SIGN_FLAGS[@]}" -s "$SIGN_IDENTITY" "$f" >/dev/null 2>&1
done

# 自检：bundle 内的二进制不得再引用 Homebrew 路径
# `|| true` 不可省：grep 无匹配时返回 1，在 set -e 下会让这条赋值直接中断构建 ——
# 也就是「检查通过」反而使构建失败。此坑已实际踩到一次。
LEAK=$(for f in "$BIN_DIR"/* "$LIB_DIR"/*; do
  [[ -f "$f" ]] && otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -E '^/opt/homebrew/|^/usr/local/'
done | sort -u || true)
if [[ -n "$LEAK" ]]; then
  echo "!!! 仍残留 Homebrew 绝对路径引用，app 在无 Homebrew 的机器上会崩："
  echo "$LEAK" | sed 's/^/    /'
  exit 1
fi
echo "    ✅ 无残留 Homebrew 路径引用"

# ---------------------------------------------------------------------------
# 随二进制一并分发许可文本 —— 这是义务，不是礼节。
# pandoc 为 GPL-2.0-or-later、libgmp 为 LGPL-3/GPL-2 双许可：分发其二进制即
# 触发「提供对应源码」的要求。typst 为 Apache-2.0，要求保留 NOTICE。
# 详见仓库根目录 THIRD-PARTY-LICENSES.md。
# ---------------------------------------------------------------------------
echo ">>> 打包第三方许可文本"
LIC_DIR="$APP_DIR/Contents/Resources/licenses"
mkdir -p "$LIC_DIR"
for pkg in pandoc typst gmp; do
  pfx=$(brew --prefix "$pkg" 2>/dev/null) || continue
  for name in COPYING.md COPYING COPYING.LESSERv3 LICENSE NOTICE; do
    [[ -f "$pfx/$name" ]] && cp "$pfx/$name" "$LIC_DIR/${pkg}-${name}"
  done
done
[[ -f "$REPO/THIRD-PARTY-LICENSES.md" ]] && cp "$REPO/THIRD-PARTY-LICENSES.md" "$LIC_DIR/"
[[ -f "$REPO/LICENSE" ]] && cp "$REPO/LICENSE" "$LIC_DIR/eink-truescale-pdf-LICENSE"
echo "    $(ls "$LIC_DIR" | wc -l | tr -d ' ') 个许可文件"

# ---------------------------------------------------------------------------
# 给整个 .app 盖封印 —— 必须是最后一步。
#
# 【此前的 bug】脚本只签了 Resources/bin 与 Resources/lib 里的单个二进制，
# 从未签过 .app 本体。swiftc 产出的可执行文件自带 ad-hoc 签名，但那只覆盖
# 它自己；把它装进 bundle 又塞进 Resources 之后，bundle 缺少 _CodeSignature/
# CodeResources，签名与内容不一致。表现为：
#   codesign --verify → "code has no resources but signature indicates
#                        they must be present"
#   spctl --assess    → rejected（exit 1）
# 用户下载后 macOS 报「已损坏，请移到废纸篓」—— 那个提示没有「仍要打开」的出路，
# 比「无法验证开发者」恶劣得多，等于彻底不可用。
#
# 【为何放在这里】封印会把 Resources 下所有文件的哈希写进 CodeResources。
# 只要之后再往 bundle 里加/改任何一个文件，封印立即失效。所以这一步必须在
# 引擎、许可、脚本、图标全部就位之后执行，位置本身就是修复的一部分。
#
# 【为何不用 --deep】Apple 已不推荐：它会覆盖内层已有签名。正确做法是
# 内层先各自签好（上面已做），再签外层 bundle。
# ---------------------------------------------------------------------------
echo ">>> 给 .app 盖封印（签名身份：$SIGN_IDENTITY）"
codesign --force "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR" 2>&1 | sed 's/^/    /'

if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
  echo "    ✅ 签名校验通过"
else
  echo "!!! 签名校验失败 —— 下载后 macOS 会报「已损坏」，不可分发："
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -5 | sed 's/^/    /'
  exit 1
fi

echo ">>> 完成: $APP_DIR"
echo "    双击访达中的 \"$APP_NAME.app\" 即可启动"
