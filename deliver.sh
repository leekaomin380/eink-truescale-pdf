#!/bin/zsh
# 剪贴板 Markdown（或 --files 指定的文件）→ PDF → QUADERNO 直连（不调用官方客户端）。
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
# Messages are zh-Hans source text, translated by the helper (QUADERNO_LANG or the macOS language).
t() { [[ -x "$DIRECT_HELPER" ]] && "$DIRECT_HELPER" text "$@" 2>/dev/null || print -r -- "$1"; }
fail() { print -ru2 -- "$1"; notify "$(t "Quaderno · 投递失败")" "$1"; exit "${2:-1}"; }

[[ -x "$DIRECT_HELPER" ]] || fail "缺少直连工具，请重新安装完整 App" 10
[[ -x "$(command -v pandoc)" ]] || fail "$(t "未找到 pandoc")" 10
[[ -x "$(command -v typst)" ]] || fail "$(t "未找到 typst")" 10
[[ -f "$TEMPLATE" ]] || fail "$(t "缺少排版模板")" 10
cd "$WORKDIR" || fail "$(t "无法进入渲染目录")" 10
JOBDIR=$(mktemp -d "$WORKDIR/quaderno_delivery.XXXXXX") || fail "$(t "无法创建临时目录")" 10
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
  print -r -- "$(t "Quaderno · 本机渲染与设备直连自检")"
  print -r -- "pandoc $(pandoc --version | head -1)"
  print -r -- "typst $(typst --version)"
  if ! printf '# 直连自检\n\n中文 CJK、\$PATH 与 @mention。\n' | pandoc -f "$MD_FORMAT" \
    --template="$TEMPLATE" "${FONTARGS[@]}" "${LAYOUTARGS[@]}" \
    -o "$JOBDIR/probe.pdf" --pdf-engine=typst "${FONTENGINEARGS[@]}" 2>"$JOBDIR/render.log"; then
    cat "$JOBDIR/render.log"; rm -f "$JOBDIR/probe.pdf"; exit 10
  fi
  print -r -- "$(t "✅ PDF 渲染通过")"
  rm -f "$JOBDIR/probe.pdf"
  "$DIRECT_HELPER" check || exit 10
  print -r -- "$(t "✅ 设备认证与目录读取通过；本次自检未上传文件。")"
  exit 0
fi

# Markdown → PDF → upload in one helper process; sets RESULT / RESULT_CODE.
render_upload() {
  local -a args=(render-upload --input "$1" --directory "$JOBDIR"
    --pandoc "$(command -v pandoc)" --typst "$(command -v typst)"
    --template "$TEMPLATE" --format "$MD_FORMAT"
    --page-width "$PAGE_W" --page-height "$PAGE_H" --margin "$PAGE_MARGIN"
    --size "$BODY_SIZE" --leading "$LEADING")
  local font
  for font in "${FONTS[@]}"; do args+=(--font "$font"); done
  [[ -d "$JOBDIR/fonts" ]] && args+=(--font-directory "$JOBDIR/fonts")
  [[ -n "${2:-}" ]] && args+=(--title "$2")
  RESULT=$("$DIRECT_HELPER" "${args[@]}")
  RESULT_CODE=$?
}
result_message() {
  printf '%s' "$RESULT" | /usr/bin/plutil -extract message raw -o - - 2>/dev/null || print -r -- "$1"
}

# Finder 右键「发送到 QUADERNO」：PDF 原样上传；Markdown / 纯文本按 Ctrl+1 排版渲染，沿用文件名。
if [[ "${1:-}" == "--files" ]]; then
  shift
  export QUADERNO_SOURCE=finder
  (( $# )) || fail "$(t "未选择文件")" 1
  SENT=0
  FAILURES=()
  for file in "$@"; do
    case "${file:e:l}" in
      pdf) RESULT=$("$DIRECT_HELPER" upload --file "$file"); RESULT_CODE=$? ;;
      md|markdown|txt) render_upload "$file" "${file:t:r}" ;;
      *) FAILURES+=("$(t "{file}：暂只支持 PDF、Markdown 和 TXT" "file=${file:t}")"); continue ;;
    esac
    if (( RESULT_CODE == 0 )); then
      (( SENT++ ))
      print -r -- "$RESULT"
    else
      print -ru2 -- "$RESULT"
      FAILURES+=("${file:t}: $(result_message "$(t "投递失败，请查看设备连接")")")
    fi
  done
  if (( ${#FAILURES} )); then
    fail "$(t "已发送 {sent} 个，失败 {failed} 个。{first}" "sent=$SENT" "failed=${#FAILURES}" "first=${FAILURES[1]}")" 4
  fi
  if (( SENT == 1 )); then
    notify "$(t "Quaderno · 已保存至 Received")" "$(result_message "$(t "已发送 1 个文件")")"
  else
    notify "$(t "Quaderno · 已保存至 Received")" "$(t "已发送 {sent} 个文件" "sent=$SENT")"
  fi
  exit 0
fi

# 自动命名仅属于剪贴板入口，不改变主窗口手动输入标题的规则。
export QUADERNO_SOURCE=clipboard
pbpaste > "$JOBDIR/input.md"
[[ -n "$(tr -d '[:space:]' < "$JOBDIR/input.md")" ]] || fail "$(t "剪贴板为空，已取消")" 1
# Single process: authenticate while rendering, then upload, open and verify.
render_upload "$JOBDIR/input.md"
MESSAGE=$(result_message "$(t "投递失败，请查看设备连接")")
if (( RESULT_CODE != 0 )); then
  print -ru2 -- "$RESULT"
  fail "$MESSAGE" 4
fi
print -r -- "$RESULT"
notify "$(t "Quaderno · 已保存至 Received")" "$MESSAGE"
