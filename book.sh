#!/bin/zsh
# =============================================================================
# book.sh · 电子书 → Quaderno 优化 PDF
# -----------------------------------------------------------------------------
# 用法：
#   ./book.sh 某本书.epub              渲染为 PDF，放在原文件旁
#   ./book.sh 某本书.epub --deliver    渲染后直接投递到设备
#   ./book.sh 某本书.epub -o out.pdf   指定输出路径
#
# 为什么单独一个脚本，而不并入 deliver.sh：
#   deliver.sh 面向剪贴板短文（几百字 / 亚秒级渲染 / 投完即弃）。
#   一本书是另一种量级：几百页、渲染以十秒计、需要分章/目录/元数据、
#   且产物应当保留而非删除。两者的参数与生命周期都不同，混在一起会互相拖累。
#
# 过去 epub 转 PDF「效果不好」的根因，多半是页面尺寸错配导致设备二次缩放，
# 叠加按纸张习惯留的大边距。本脚本按设备显示区物理尺寸出页，1:1 零缩放。
# =============================================================================

set -uo pipefail
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/config.sh"
TEMPLATE="$SCRIPT_DIR/deliver.typ"

die() { print -r -- "❌ $1" >&2; exit "${2:-1}"; }

# ---- 参数解析 ---------------------------------------------------------------
SRC=""; OUT=""; DELIVER=0; PLAIN=0
while (( $# )); do
  case "$1" in
    --deliver|-d) DELIVER=1 ;;
    --plain)      PLAIN=1 ;;
    --lang)       shift; DOC_LANG="${1:-zh}" ;;
    --page)       shift; PAGE_W="${1}"; shift; PAGE_H="${1}" ;;
    --size)       shift; BODY_SIZE="${1:-10pt}" ;;
    --font)       shift; FONTS=("${(@s:,:)1}") ;;      # 逗号分隔：拉丁在前，CJK 在后
    --margin)     shift; PAGE_MARGIN="${1:-10mm}" ;;
    --leading)    shift; LEADING="${1:-0.85em}" ;;
    -o)           shift; OUT="${1:-}" ;;
    -h|--help)
      print -r -- "用法: book.sh <书文件> [-o 输出.pdf] [--deliver]"
      print -r -- "支持: epub / fb2 / html / md（mobi/azw 需安装 calibre）"
      print -r -- ""
      print -r -- "选项:"
      print -r -- "  --lang zh|en      文档语言，影响目录标题与 CJK 断行（默认 zh）"
      print -r -- "  --size 11pt       正文字号（默认 $BODY_SIZE）"
      print -r -- "  --font \"A,B\"      字体 fallback，逗号分隔，拉丁在前 CJK 在后"
      print -r -- "  --margin 12mm     页边距（默认 $PAGE_MARGIN）"
      print -r -- "  --leading 0.9em   行距（默认 $LEADING）"
      print -r -- ""
      print -r -- "建议范围（页宽 $PAGE_W，1:1 无缩放前提下）:"
      print -r -- "  中文  10-12pt  —— 10.5pt 即传统五号，中文书正文标准字号"
      print -r -- "                    目标 32-40 字/行；黑体类优于宋体（见下）"
      print -r -- "  英文  11-12.5pt —— 拉丁字符窄，同样版心下字号需比中文大，"
      print -r -- "                    否则每行超 75 字符，超出理想行长上限"
      print -r -- "  边距  10-14mm   行距 0.8-1.0em"
      print -r -- ""
      print -r -- "字体选择：墨水屏 227ppi 且对比度低于印刷，高笔画对比度的字体"
      print -r -- "（宋体/明朝体、Didone 类衬线）细横笔会被抗锯齿冲淡，显灰发虚。"
      print -r -- "宜选笔画均匀的黑体/无衬线，或低对比度衬线（如 Charter）。"
      exit 0 ;;
    *)            SRC="$1" ;;
  esac
  shift
done

[[ -n "$SRC" ]]  || die "未指定输入文件。用法: book.sh <书文件> [--deliver]"
[[ -f "$SRC" ]]  || die "文件不存在: $SRC"
command -v pandoc >/dev/null || die "未找到 pandoc → brew install pandoc" 10
command -v typst  >/dev/null || die "未找到 typst → brew install typst"  10
[[ -f "$TEMPLATE" ]] || die "缺少模板 deliver.typ" 10

SRC="${SRC:A}"                       # 绝对路径
EXT="${${SRC:t:e}:l}"                # 小写扩展名
BASE="${SRC:t:r}"

# ---- mobi/azw：经 calibre 转 epub 中转 --------------------------------------
WORK="$WORKDIR/booksh_$$"
mkdir -p "$WORK" || die "无法创建工作目录"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

case "$EXT" in
  epub|fb2|html|htm|md|markdown|txt) INPUT="$SRC" ;;
  mobi|azw|azw3|prc)
    command -v ebook-convert >/dev/null \
      || die "$EXT 需要 calibre 转换 → brew install --cask calibre
       （注：带 DRM 保护的文件无法转换）" 10
    print -r -- "→ $EXT 经 calibre 转 epub 中转…"
    INPUT="$WORK/converted.epub"
    ebook-convert "$SRC" "$INPUT" >/dev/null 2>&1 \
      || die "calibre 转换失败（该文件可能有 DRM 保护）"
    ;;
  *) die "不支持的格式: .$EXT（支持 epub/fb2/html/md，mobi/azw 需 calibre）" ;;
esac

# ---- 输入格式判定 -----------------------------------------------------------
case "${${INPUT:t:e}:l}" in
  epub)          FROM="epub" ;;
  fb2)           FROM="fb2" ;;
  html|htm)      FROM="html" ;;
  *)             FROM="$MD_FORMAT" ;;
esac

[[ -n "$OUT" ]] || OUT="${SRC:h}/${BASE}.pdf"

# ---- 渲染 -------------------------------------------------------------------
FONTARGS=(); for f in "${FONTS[@]}"; do FONTARGS+=(-V "mainfont=$f"); done

# --plain 模式不加目录与分章（粘贴文本用）
EXTRA_ARGS=()
if (( ! PLAIN )); then
  EXTRA_ARGS+=(--toc --toc-depth=3 -V chapterbreak=true)
fi

print -r -- "→ 渲染中：${SRC:t}"
print -r -- "   页面 $PAGE_W × $PAGE_H · 边距 $PAGE_MARGIN · 正文 $BODY_SIZE"
print -r -- "   一本书可能需要数十秒，请稍候…"

START=$(date +%s)
cd "$WORK" || die "无法进入工作目录"     # 铁律：pandoc 需可写沙盒（提取 epub 内嵌图片）

if ! pandoc "$INPUT" -f "$FROM" \
      --template="$TEMPLATE" \
      "${EXTRA_ARGS[@]}" \
      -V "lang=$DOC_LANG" \
      --lua-filter="$SCRIPT_DIR/book-filter.lua" \
      -M date="" \
      "${FONTARGS[@]}" \
      -V "pagewidth=$PAGE_W" -V "pageheight=$PAGE_H" -V "pagemargin=$PAGE_MARGIN" \
      -V "bodysize=$BODY_SIZE" -V "leading=$LEADING" \
      -o "$OUT" --pdf-engine=typst 2>"$WORK/err.log"; then
  print -r -- ""
  print -r -- "渲染失败，pandoc 报错："
  tail -20 "$WORK/err.log" >&2
  die "渲染未完成" 2
fi

ELAPSED=$(( $(date +%s) - START ))
SIZE=$(stat -f%z "$OUT" 2>/dev/null)
PAGES=$(python3 -c "
import re,sys
d=open('$OUT','rb').read()
m=re.findall(rb'/Count\s+(\d+)',d)
print(max(int(x) for x in m) if m else '?')" 2>/dev/null || echo "?")

print -r -- ""
print -r -- "✅ 完成：$OUT"
print -r -- "   ${PAGES} 页 · $(( SIZE / 1024 )) KB · 耗时 ${ELAPSED}s"
if (( PLAIN )); then
  print -r -- "   plain 模式：无目录页、无强制分章"
else
  print -r -- "   已生成 PDF 大纲（书签）与正文目录页"
fi

# ---- 可选投递 ---------------------------------------------------------------
if (( DELIVER )); then
  [[ -d "$QUADERNO_APP" ]] || die "未找到 QUADERNO 客户端"
  # 客户端会在上传后删除源文件，故投递副本，保留原始产物。
  # 副本名必须与 OUT 不同 —— 若 OUT 本身就落在 WORKDIR 内（如 -o /tmp/x.pdf），
  # 同名会导致 cp 自拷贝失败，客户端随后把原始产物吃掉，等于静默数据丢失。
  COPY="$WORK/deliver_${OUT:t}"
  cp "$OUT" "$COPY" || die "无法创建投递副本"
  print -r -- "→ 投递到设备…"
  open -gj -na "$QUADERNO_APP" --args --print "$COPY"
  for i in $(seq 1 300); do [[ -f "$COPY" ]] || break; sleep 0.2; done
  if [[ -f "$COPY" ]]; then
    print -r -- "⚠️  60 秒内未确认送达 —— 书较大时上传耗时更长，请检查客户端"
    rm -f "$COPY"
  else
    print -r -- "✅ 已投递（原始 PDF 保留在 $OUT）"
  fi
fi
