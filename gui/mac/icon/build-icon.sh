#!/usr/bin/env bash
# 从 icon.mjs 出全套 macOS 图标并打包成 AppIcon.icns。
#
# 光栅化优先用 rsvg-convert（快、无 GUI）；没有则回退 Chrome headless。
# 不要用 ImageMagick —— 它自带的 MSVG 渲染器不支持 <filter> 和渐变描边，
# 出来的图没有投影也没有纸的厚度。
#
# 用法：gui/mac/icon/build-icon.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$HERE/.." && pwd)"
OUT_ICNS="$MAC_DIR/AppIcon.icns"
OUT_PNG="$MAC_DIR/AppIcon_1024.png"

command -v node >/dev/null || { echo "需要 node"; exit 1; }
command -v iconutil >/dev/null || { echo "需要 iconutil（Xcode Command Line Tools）"; exit 1; }

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || CHROME="/Applications/Chromium.app/Contents/MacOS/Chromium"

if command -v rsvg-convert >/dev/null; then
  RASTER=rsvg
elif [[ -x "$CHROME" ]]; then
  RASTER=chrome
else
  echo "找不到光栅化工具。装其一：" >&2
  echo "  brew install librsvg     # 推荐" >&2
  echo "  或安装 Google Chrome" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET_DIR="$WORK/AppIcon.iconset"
mkdir -p "$SET_DIR"

render() {  # $1 = px, $2 = 输出 png
  local px="$1" out="$2" svg="$WORK/i$px.svg"
  node "$HERE/icon.mjs" "$px" > "$svg"
  if [[ "$RASTER" == rsvg ]]; then
    rsvg-convert -w "$px" -h "$px" "$svg" -o "$out"
  else
    local html="$WORK/i$px.html"
    printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent}svg{display:block}</style>' > "$html"
    cat "$svg" >> "$html"
    "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
      --default-background-color=00000000 --window-size="$px,$px" \
      --screenshot="$out" "file://$html" >/dev/null 2>&1
  fi
  [[ -s "$out" ]] || { echo "渲染失败: ${px}px" >&2; exit 1; }
}

# macOS iconset 需要的 10 个条目，来自 7 个实际渲染尺寸。
# 每一档都是重新排版过的，不是缩放 —— 见 icon.mjs 的 TIERS。
# （macOS 自带 bash 3.2，没有关联数组，所以先渲染再按名字复制。）
for px in 16 32 64 128 256 512 1024; do
  render "$px" "$WORK/$px.png"
  printf '  %4spx  ✓\n' "$px"
done

cp "$WORK/16.png"   "$SET_DIR/icon_16x16.png"
cp "$WORK/32.png"   "$SET_DIR/icon_16x16@2x.png"
cp "$WORK/32.png"   "$SET_DIR/icon_32x32.png"
cp "$WORK/64.png"   "$SET_DIR/icon_32x32@2x.png"
cp "$WORK/128.png"  "$SET_DIR/icon_128x128.png"
cp "$WORK/256.png"  "$SET_DIR/icon_128x128@2x.png"
cp "$WORK/256.png"  "$SET_DIR/icon_256x256.png"
cp "$WORK/512.png"  "$SET_DIR/icon_256x256@2x.png"
cp "$WORK/512.png"  "$SET_DIR/icon_512x512.png"
cp "$WORK/1024.png" "$SET_DIR/icon_512x512@2x.png"

iconutil -c icns "$SET_DIR" -o "$OUT_ICNS"
cp "$WORK/1024.png" "$OUT_PNG"

echo "出图完成（$RASTER）"
echo "  $OUT_ICNS  ($(du -h "$OUT_ICNS" | cut -f1))"
echo "  $OUT_PNG"
