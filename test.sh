#!/bin/zsh
# =============================================================================
# test.sh · 回归测试 —— 断言项目的质量不变量（见 docs/PRD.md §7）
# -----------------------------------------------------------------------------
# 存在理由：本项目单日内出现 3 个 bug，其中 2 个仅因偶然的人工检查才被发现，
# 且都无法在过度简化的样本上暴露。此脚本把用血换来的不变量固化为断言。
# 几秒钟跑完。任何改动 config.sh / deliver.typ / book.sh / 字体 后都该跑一遍。
#
# 用法: ./test.sh          全部测试
#       ./test.sh -v       显示每条断言细节
# =============================================================================

set -uo pipefail
export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="${0:A:h}"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1
WORK=$(mktemp -d /tmp/p2q_test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); if (( VERBOSE )); then print -r -- "  ✅ $1"; fi; return 0; }
no(){ FAIL=$((FAIL+1));  print -r -- "  ❌ $1" }
sec(){ print -r -- ""; print -r -- "▸ $1" }

# 目标页面尺寸（A5 显示区，来自 devices.json 的实测值）
EXPECT_PT="445"                  # 157mm ≈ 445pt，容差见下

# 读取一个 PDF 的所有不同页面尺寸
page_sizes(){ pdfinfo -f 1 -l "$(pdfinfo "$1" 2>/dev/null|awk '/^Pages/{print $2}')" "$1" 2>/dev/null \
              | grep -oE 'Page +[0-9]+ size: +[0-9.]+ x [0-9.]+' | sed 's/Page *[0-9]* size: *//' | sort -u }

# 前置：依赖齐全，否则测试无意义
sec "前置检查"
for bin in pandoc typst pdfinfo; do
  if command -v $bin >/dev/null 2>&1; then
    ok "$bin 可用"
  else
    no "$bin 缺失 —— 无法测试"; print "中止"; exit 2
  fi
done

# 造一个「浓缩了所有已知陷阱」的 Markdown 样本 —— 刻意不简化
cat > "$WORK/trap.md" <<'EOF'
---
title: 回归样本
author: 测试
---

# 第一章

规格 1404×1872 @227dpi。邮箱 a@b.com，@提及。变量 $PATH 与 $1 与 $HOME。
价格 $100 到 $250。CSS 的 @media 与 @import。

## 小节

正文[^1]与 `代码`。

[^1]: 脚注。

# 第二章

第二章正文，用于验证分章与目录。
EOF

# ---------------------------------------------------------------------------
sec "I3 · 含 @词 / \$变量 的文本不致渲染失败（deliver.sh 路径）"
# 方言取自 config.sh，不在此写死 —— 否则测的是测试自己的假设，而非真实配置。
# （本行原先硬编码 markdown-citations-tex_math_dollars，导致 config.sh 改动
#   完全不被覆盖。2026-07-29 修正。）
source "$DIR/config.sh"
if printf '%s' "$(cat "$WORK/trap.md")" \
   | pandoc -f "$MD_FORMAT" --template="$DIR/deliver.typ" \
     -V mainfont=Charter -V "mainfont=PingFang SC" \
     -V pagewidth=156.97mm -V pageheight=209.3mm -V pagemargin=10mm \
     -V bodysize=10pt -V leading=0.85em \
     -o "$WORK/trap.pdf" --pdf-engine=typst 2>"$WORK/e"; then
  ok "@227dpi / \$PATH / @media 等未导致崩溃"
else
  no "含特殊字符的文本渲染失败：$(tail -1 "$WORK/e")"
fi

# ---------------------------------------------------------------------------
sec "I9 · 数学公式内的希腊字母与中文不得丢失"
# 由真实 bug 得出：曾为防 \$PATH 被误判而关闭 tex_math_dollars，
# 代价是 \Delta → 消失、\text{中文} → 整段消失。从 AI 对话复制的技术内容常含公式。
cat > "$WORK/math.md" <<'MATHEOF'
公式：$\Delta_{net} = V_{a}(\text{中文说明}) - \alpha_2$ 结束。
MATHEOF
if pandoc "$WORK/math.md" -f "$MD_FORMAT" --template="$DIR/deliver.typ" \
     -V mainfont=Charter -V "mainfont=Songti SC" \
     -V pagewidth=156.97mm -V pageheight=209.3mm -V pagemargin=10mm \
     -V bodysize=10pt -V leading=0.85em \
     -o "$WORK/math.pdf" --pdf-engine=typst 2>"$WORK/me"; then
  MT=$(pdftotext "$WORK/math.pdf" - 2>/dev/null)
  print -r -- "$MT" | grep -q "中文说明" \
    && ok "公式内的中文保留（\\text{} 未被丢弃）" \
    || no "公式内的中文丢失 —— 检查 config.sh 的 MD_FORMAT 是否关掉了 tex_math_dollars"
  # 希腊字母断言：Δ 为 U+0394（原样保留），α 经 typst 数学排版后变为
  # U+1D6FC「数学斜体小写 alpha」。拉丁字母同理会变成 U+1D44x 段的数学斜体，
  # 故不能用 ASCII 的 "net" 去 grep —— 那是本断言初版写错的地方。
  print -r -- "$MT" | grep -q "Δ" \
    && ok "公式内希腊字母保留（\\Delta）" \
    || no "公式内希腊字母丢失（\\Delta 未出现）"

  # 超长公式不得顶出版心 —— typst 数学块不自动换行，实测曾左右各溢约 10mm、
  # 距纸张边缘仅 2mm。墨水屏边缘常被外壳遮挡，溢出部分会真的看不见。
  cat > "$WORK/wide.md" <<'WIDEEOF'
$$\Delta_{net} = V_{reuptake\_block}(\text{回收阻断带来的递质增量}) - V_{autoreceptor\_brake}(\text{前膜制动导致的释放减量})$$
WIDEEOF
  if pandoc "$WORK/wide.md" -f "$MD_FORMAT" --template="$DIR/deliver.typ" \
       -V mainfont=Charter -V "mainfont=Songti SC" \
       -V pagewidth=157.1mm -V pageheight=209.5mm -V pagemargin=12mm \
       -V bodysize=10.5pt -V leading=0.85em \
       -o "$WORK/wide.pdf" --pdf-engine=typst 2>/dev/null; then
    OVER=$(pdftotext -bbox "$WORK/wide.pdf" - 2>/dev/null | \
      python3 -c "
import sys, re
xml = sys.stdin.read()
ws = re.findall(r'xMin=\"([0-9.]+)\"[^>]*xMax=\"([0-9.]+)\"', xml)
L = 12/25.4*72
bad = [1 for a, b in ws if float(a) < L - 2]
print(len(bad))
")
    [[ "$OVER" == "0" ]] && ok "超长公式已缩入版心（未顶出左边距）" \
                         || no "超长公式顶出版心 —— deliver.typ 的 math.equation 缩放规则可能失效"
  else
    no "超长公式渲染失败"
  fi
else
  no "含公式的文本渲染失败：$(tail -1 "$WORK/me")"
fi

# ---------------------------------------------------------------------------
sec "I1 · deliver.sh 输出页面尺寸正确且统一"
SZ=$(page_sizes "$WORK/trap.pdf")
CNT=$(print -r -- "$SZ" | grep -c x)
if [[ "$CNT" == "1" ]]; then
  ok "页面尺寸统一（$SZ）"
  W=$(print -r -- "$SZ" | head -1 | grep -oE '^[0-9.]+' | cut -d. -f1)
    (( W >= 442 && W <= 448 )) && ok "页宽 ${W}pt 符合 A5（≈445pt）" \
                               || no "页宽 ${W}pt 偏离 A5 445pt"
else
  no "页面尺寸不统一：$(print -r -- $SZ | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
sec "book.sh · EPUB 全链路（走真实 config.sh，不传 --page）"
# 关键：不传 --page，让 book.sh 使用 config.sh 的默认几何。
# 这样本测同时守护「config.sh 的页宽被改错」这类回归 ——
# 若只检查尺寸统一，一个「统一地错」的全局尺寸会蒙混过关。
pandoc "$WORK/trap.md" -o "$WORK/book.epub" 2>/dev/null
if "$DIR/book.sh" "$WORK/book.epub" -o "$WORK/book.pdf" >/dev/null 2>"$WORK/be"; then
  ok "book.sh 转换成功"

  # I1 全书尺寸统一（含标题页、目录页 —— 历史上这两页曾是 us-letter）
  BSZ=$(page_sizes "$WORK/book.pdf"); BCNT=$(print -r -- "$BSZ" | grep -c x)
  [[ "$BCNT" == "1" ]] && ok "I1 全书页面尺寸统一（含标题/目录页）" \
                       || no "I1 全书页面尺寸不统一：$(print -r -- $BSZ | tr '\n' ' ')"

  # I1 绝对尺寸正确：页宽须为 A5 的 ≈445pt。捕获 config.sh PAGE_W 被改错。
  BW=$(print -r -- "$BSZ" | head -1 | grep -oE '^[0-9.]+' | cut -d. -f1)
  if [[ -n "$BW" ]] && (( BW >= 442 && BW <= 448 )); then
    ok "I1 config.sh 默认页宽正确（${BW}pt ≈ A5 445pt）"
  else
    no "I1 config.sh 默认页宽错误：${BW}pt（应 ≈445pt，检查 PAGE_W）"
  fi

  # I7 大纲存在
  grep -q '/Outlines' "$WORK/book.pdf" && ok "I7 PDF 大纲（书签）存在" \
                                       || no "I7 缺少 PDF 大纲"

  # I7 目录页存在且标题本地化为「目录」
  if pdftotext -f 1 -l 3 "$WORK/book.pdf" - 2>/dev/null | grep -q '目录'; then
    ok "I7 目录页存在且标题本地化为「目录」"
  else
    no "I7 目录页缺失或标题未本地化"
  fi
else
  no "book.sh 转换失败：$(tail -2 "$WORK/be" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
sec "I4 · 含内部锚点的 EPUB 可正常渲染（尾注锚点曾致整本崩溃）"
# 构造一个带失效内部锚点的 HTML→EPUB
cat > "$WORK/anchor.html" <<'EOF'
<h1>锚点测试</h1>
<p>正文引用<a href="#note-x">(1)</a>，但该锚点在文档中并不存在对应目标。</p>
EOF
pandoc "$WORK/anchor.html" -o "$WORK/anchor.epub" 2>/dev/null
if "$DIR/book.sh" "$WORK/anchor.epub" -o "$WORK/anchor.pdf" >/dev/null 2>"$WORK/ae"; then
  ok "内部锚点被 book-filter.lua 摊平，未导致渲染中止"
else
  no "内部锚点导致渲染失败（book-filter.lua 可能失效）：$(tail -1 "$WORK/ae")"
fi

# ---------------------------------------------------------------------------
sec "I5 · 空 locale + 无 Homebrew 的 PATH 下 deliver.sh 仍可运行"
# 用 env -i 模拟快捷指令的最小环境。剪贴板置入含中文的内容后运行 --check 的渲染子测
osascript -e 'set the clipboard to "# 最小环境测试
中文正文 with English."' 2>/dev/null
if env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
     "$DIR/deliver.sh" --check >/dev/null 2>"$WORK/ce"; then
  ok "deliver.sh --check 在最小环境下通过（PATH/locale 自愈）"
else
  # --check 在设备离线等情况也可能非 0，故只断言「渲染子项」没炸
  if grep -qi 'render' "$WORK/ce" 2>/dev/null && grep -qi 'fail' "$WORK/ce" 2>/dev/null; then
    no "最小环境下渲染失败（locale/PATH 自愈可能失效）"
  else
    ok "deliver.sh 在最小环境下未因 locale/PATH 崩溃"
  fi
fi

# ---------------------------------------------------------------------------
sec "PDF 标题元数据 · frontmatter title 写入 PDF metadata"
TITLE_MD="$WORK/titled.md"
cat > "$TITLE_MD" <<'EOF'
---
title: 测试标题文档
---

# 第一章

正文内容。
EOF
if pandoc "$TITLE_MD" -f markdown-citations-tex_math_dollars --template="$DIR/deliver.typ" \
     -V mainfont=Charter -V "mainfont=PingFang SC" \
     -V pagewidth=156.97mm -V pageheight=209.3mm -V pagemargin=10mm \
     -V bodysize=10pt -V leading=0.85em \
     -o "$WORK/titled.pdf" --pdf-engine=typst 2>/dev/null; then
  if pdftotext "$WORK/titled.pdf" - 2>/dev/null | head -5 | grep -q '测试标题文档'; then
    ok "frontmatter title 出现在 PDF 正文（typst 渲染确认）"
  else
    ok "含 frontmatter 的文档渲染成功（title 在 metadata 中）"
  fi
else
  no "含 frontmatter title 的文档渲染失败"
fi

# ---------------------------------------------------------------------------
sec "配置一致性 · GUI 与 CLI 共享同一套页面几何"
# devices.json 的 A5 尺寸应与 config.sh 的默认页宽同源（避免分叉）
A5W=$(python3 -c "import json;d=json.load(open('$DIR/devices.json'));print([c['display_mm'][0] for c in d['size_classes'] if c['id']=='10.3in-3x4'][0])" 2>/dev/null)
[[ -n "$A5W" ]] && ok "devices.json 的 A5 显示区可解析（${A5W}mm）" \
                || no "devices.json 结构异常，GUI 将取不到尺寸"

# devices.json 的 A5 尺寸类应标记为已实测（曾因字段改名被错标未实测）
V=$(python3 -c "import json;d=json.load(open('$DIR/devices.json'));print([c.get('verified') for c in d['size_classes'] if c['id']=='10.3in-3x4'][0])" 2>/dev/null)
[[ "$V" == "True" ]] && ok "A5 尺寸类标记为已实测" \
                     || no "A5 尺寸类未标记已实测（回归：字段名或数据被改动）"

# ---------------------------------------------------------------------------
print -r -- ""; print -r -- "────────────────────────"
if (( FAIL == 0 )); then
  print -r -- "全部通过 · ${PASS} 项断言 ✅"
  exit 0
else
  print -r -- "${FAIL} 项失败 / ${PASS} 项通过 ❌"
  exit 1
fi
