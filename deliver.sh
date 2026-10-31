#!/bin/zsh
# 剪贴板 Markdown → 自动命名 PDF → QUADERNO 直连（不调用官方客户端）。
set -uo pipefail
export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
SCRIPT_DIR="${0:A:h}"
export PATH="$SCRIPT_DIR/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
source "$SCRIPT_DIR/config.sh"
TEMPLATE="$SCRIPT_DIR/deliver.typ"
DIRECT_HELPER="$SCRIPT_DIR/direct/quaderno-direct"
[[ -x "$DIRECT_HELPER" ]] || DIRECT_HELPER="$SCRIPT_DIR/direct/runtime-dist/quaderno-direct/quaderno-direct"

notify() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}
fail() { print -ru2 -- "$1"; notify "Quaderno · 投递失败" "$1"; exit "${2:-1}"; }

[[ -x "$DIRECT_HELPER" ]] || fail "缺少直连工具，请重新安装完整 App" 10
[[ -x "$(command -v pandoc)" ]] || fail "未找到 pandoc" 10
[[ -x "$(command -v typst)" ]] || fail "未找到 typst" 10
[[ -f "$TEMPLATE" ]] || fail "缺少排版模板" 10
cd "$WORKDIR" || fail "无法进入渲染目录" 10
JOBDIR=$(mktemp -d "$WORKDIR/quaderno_delivery.XXXXXX") || fail "无法创建临时目录" 10
trap 'rm -rf "$JOBDIR/fonts"; rm -f "$JOBDIR/input.md" "$JOBDIR/render.md" "$JOBDIR/render.log"; rmdir "$JOBDIR" 2>/dev/null || true' EXIT
FONTARGS=(); for font in "${FONTS[@]}"; do FONTARGS+=(-V "mainfont=$font"); done
LAYOUTARGS=(-V "pagewidth=$PAGE_W" -V "pageheight=$PAGE_H" -V "pagemargin=$PAGE_MARGIN" -V "bodysize=$BODY_SIZE" -V "leading=$LEADING")

# Default fonts are fixed for clipboard delivery. Scan only these local font files;
# custom configurations keep normal system discovery. Font files are not copied/bundled.
FONTENGINEARGS=()
if [[ "${(j:,:)FONTS}" == "Times New Roman,Songti SC" ]]; then
  FONTFILES=(
    "/System/Library/Fonts/STHeiti Medium.ttc"
    "/System/Library/Fonts/STHeiti Light.ttc"
    "/System/Library/Fonts/Supplemental/Songti.ttc"
    "/System/Library/Fonts/Supplemental/Times New Roman.ttf"
    "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf"
    "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf"
    "/System/Library/Fonts/Supplemental/Times New Roman Bold Italic.ttf"
  )
  FONTS_PRESENT=1
  for fontfile in "${FONTFILES[@]}"; do [[ -f "$fontfile" ]] || FONTS_PRESENT=0; done
  if (( FONTS_PRESENT )); then
    mkdir "$JOBDIR/fonts"
    for fontfile in "${FONTFILES[@]}"; do ln -s "$fontfile" "$JOBDIR/fonts/${fontfile:t}"; done
    FONTENGINEARGS=(--pdf-engine-opt=--ignore-system-fonts "--pdf-engine-opt=--font-path=$JOBDIR/fonts")
  fi
fi

if [[ "${1:-}" == "--check" || "${1:-}" == "-c" ]]; then
  print -r -- "Quaderno · 本机渲染与设备直连自检"
  print -r -- "pandoc $(pandoc --version | head -1)"
  print -r -- "typst $(typst --version)"
  if ! printf '# 直连自检\n\n中文 CJK、\$PATH 与 @mention。\n' | pandoc -f "$MD_FORMAT" \
    --template="$TEMPLATE" "${FONTARGS[@]}" "${LAYOUTARGS[@]}" \
    -o "$JOBDIR/probe.pdf" --pdf-engine=typst "${FONTENGINEARGS[@]}" 2>"$JOBDIR/render.log"; then
    cat "$JOBDIR/render.log"; rm -f "$JOBDIR/probe.pdf"; exit 10
  fi
  print -r -- "✅ PDF 渲染通过"
  rm -f "$JOBDIR/probe.pdf"
  "$DIRECT_HELPER" check || exit 10
  print -r -- "✅ 设备认证与目录读取通过；本次自检未上传文件。"
  exit 0
fi

# 自动命名仅属于剪贴板入口，不改变主窗口手动输入标题的规则。
pbpaste > "$JOBDIR/input.md"
[[ -n "$(tr -d '[:space:]' < "$JOBDIR/input.md")" ]] || fail "剪贴板为空，已取消" 1
# Single process: authenticate while rendering, then upload, open and verify.
RENDERARGS=(render-upload --input "$JOBDIR/input.md" --directory "$JOBDIR"
  --pandoc "$(command -v pandoc)" --typst "$(command -v typst)"
  --template "$TEMPLATE" --format "$MD_FORMAT"
  --page-width "$PAGE_W" --page-height "$PAGE_H" --margin "$PAGE_MARGIN"
  --size "$BODY_SIZE" --leading "$LEADING")
for font in "${FONTS[@]}"; do RENDERARGS+=(--font "$font"); done
[[ -d "$JOBDIR/fonts" ]] && RENDERARGS+=(--font-directory "$JOBDIR/fonts")
RESULT=$("$DIRECT_HELPER" "${RENDERARGS[@]}")
RESULT_CODE=$?
MESSAGE=$(printf '%s' "$RESULT" | /usr/bin/plutil -extract message raw -o - - 2>/dev/null) || MESSAGE="投递失败，请查看设备连接"
if (( RESULT_CODE != 0 )); then
  print -ru2 -- "$RESULT"
  fail "$MESSAGE" 4
fi
print -r -- "$RESULT"
notify "Quaderno · 已保存至 Received" "$MESSAGE"
