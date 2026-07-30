#!/bin/zsh
# =============================================================================
# deliver.sh  ·  剪贴板 Markdown → Quaderno 墨水屏 · 零 GUI 投递管道
# -----------------------------------------------------------------------------
# 用法：绑到全局热键（Raycast Script Command / macOS 快捷指令），无参运行即可。
# 流程：抓剪贴板 → pandoc+typst 渲染 PDF → open -gj 后台投递 → 监听日志给出真实反馈
# 设计依据见项目 README。作者约定的铁律：强制 /tmp 沙盒、指令与数据物理隔离。
# =============================================================================


set -uo pipefail

# 铁律①：强制 UTF-8 locale。快捷指令等最小化环境常不带 locale，
# 缺失时 pandoc 会把 UTF-8 中文误判为 latin1 → 设备上一片乱码。
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# 铁律②：快捷指令给的 PATH 只有 /usr/bin:/bin，不含 Homebrew。
# 不补 /opt/homebrew/bin，热键触发时会找不到 pandoc/typst。
# .app 内自带 pandoc/typst 时优先用它们 —— 这是「装上就能用、无需 Homebrew」的关键。
# SCRIPT_DIR 在 .app 中即 Contents/Resources，故 bin/ 与本脚本同级；
# 从 git 检出直接运行时该目录不存在，自然回退到 Homebrew，两种用法都成立。
_BUNDLED_BIN="${0:A:h}/bin"
if [[ -x "$_BUNDLED_BIN/pandoc" ]]; then
  export PATH="$_BUNDLED_BIN:/opt/homebrew/bin:/usr/local/bin:$PATH"
else
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/config.sh"   # 页面几何、字体、方言等共享配置
DELIVER_TIMEOUT=15                 # 监听送达结果的最长秒数
TEMPLATE="$SCRIPT_DIR/deliver.typ"
OUT="$WORKDIR/quaderno_delivery_$$.pdf"     # PID 命名，隔离并发；若检测到标题会重命名
ERRLOG="$WORKDIR/quaderno_render_$$.log"

# macOS 系统通知（$1=标题 $2=正文 $3=声音，缺省无声）
notify() {
  local sound="${3:-}"
  if [[ -n "$sound" ]]; then
    osascript -e "display notification \"$2\" with title \"$1\" sound name \"$sound\"" >/dev/null 2>&1
  else
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
  fi
}

fail() { notify "Quaderno ❌" "$1" "Basso"; rm -f "$OUT"; exit "${2:-1}"; }

# ---- --check：全链路自检 ---------------------------------------------------
# 存在理由：本管道有 5 个彼此独立的环节，且大多数环节失败时是「静默」的
# （客户端不提示、快捷指令不报错）。把开发期踩过的坑固化成一条可运行的诊断。
if [[ "${1:-}" == "--check" || "${1:-}" == "-c" ]]; then
  ok=0; bad=0
  pass() { print -r -- "  ✅ $1"; ((ok++)); }
  warn() { print -r -- "  ⚠️  $1"; }
  nope() { print -r -- "  ❌ $1"; ((bad++)); }

  print -r -- "print-to-quaderno · self check"
  print -r -- ""
  print -r -- "Environment"
  print -r -- "  ·  LANG=$LANG  PATH includes Homebrew: $([[ ":$PATH:" == *":/opt/homebrew/bin:"* ]] && echo yes || echo no)"

  print -r -- ""
  print -r -- "Dependencies"
  if command -v pandoc >/dev/null 2>&1; then pass "pandoc $(pandoc --version | head -1 | awk '{print $2}')"
  else nope "pandoc not found  →  brew install pandoc"; fi
  if command -v typst  >/dev/null 2>&1; then pass "typst $(typst --version | awk '{print $2}')"
  else nope "typst not found  →  brew install typst"; fi

  print -r -- ""
  print -r -- "Files"
  [[ -f "$TEMPLATE" ]] && pass "template deliver.typ" || nope "deliver.typ missing next to deliver.sh"
  [[ -w "$WORKDIR"  ]] && pass "sandbox $WORKDIR writable" || nope "$WORKDIR not writable"

  print -r -- ""
  print -r -- "QUADERNO client"
  if [[ -d "$QUADERNO_APP" ]]; then pass "app installed"
  else nope "QUADERNO PC App not found in /Applications"; fi
  if pgrep -f "QUADERNO PC App" >/dev/null 2>&1; then pass "client is running"
  else warn "client not running — it will be launched on demand, but the device must be connected"; fi
  LOGPROBE=$(find "$HOME/Library/Application Support/Fujitsu" -name logfile.log -type f 2>/dev/null | head -1)
  [[ -f "$LOGPROBE" ]] && pass "client log found (used to confirm delivery)" \
                       || warn "client log not found — delivery result cannot be verified"

  print -r -- ""
  print -r -- "Clipboard"
  if command -v pbpaste >/dev/null 2>&1; then
    CB=$(pbpaste 2>/dev/null | wc -m | tr -d ' ')
    [[ "$CB" -gt 0 ]] && pass "readable, currently $CB chars" || warn "readable, but currently empty"
  else nope "pbpaste unavailable"; fi

  print -r -- ""
  print -r -- "Render test"
  PROBE="$WORKDIR/quaderno_selftest_$$.pdf"
  if printf '# self test\n\n中文 CJK check, \$PATH and @mention must survive.\n' \
     | pandoc -f "$MD_FORMAT" --template="$TEMPLATE" \
              -V "mainfont=${FONTS[1]}" -V "mainfont=${FONTS[2]}" \
              -V "pagewidth=$PAGE_W" -V "pageheight=$PAGE_H" -V "pagemargin=$PAGE_MARGIN" \
              -V "bodysize=$BODY_SIZE" -V "leading=$LEADING" \
              -o "$PROBE" --pdf-engine=typst 2>/dev/null; then
    pass "pipeline renders a PDF ($(stat -f%z "$PROBE" 2>/dev/null) bytes)"
    rm -f "$PROBE"
  else
    nope "render pipeline failed — run deliver.sh with text copied to see the error"
  fi

  print -r -- ""
  if (( bad > 0 )); then
    print -r -- "$bad problem(s) found. Fix the ❌ items above, then run --check again."
    exit 10
  fi
  print -r -- "All checks passed. Copy some Markdown and press your hotkey."
  print -r -- "Note: a connected device is still required — confirm the client shows \"Connected\"."
  exit 0
fi

# ---- 0. 前置检查 -----------------------------------------------------------
[[ -x "$(command -v pandoc)" ]] || fail "未找到 pandoc" 10
[[ -x "$(command -v typst)"  ]] || fail "未找到 typst"  10
[[ -d "$QUADERNO_APP" ]]        || fail "未找到 QUADERNO 客户端" 10
[[ -f "$TEMPLATE" ]]           || fail "缺少模板 deliver.typ" 10

# ---- 1. 抓剪贴板 + 空检测 --------------------------------------------------
PAYLOAD="$(pbpaste 2>/dev/null)"
# 去掉纯空白后判空
if [[ -z "${PAYLOAD//[$' \t\r\n']/}" ]]; then
  fail "剪贴板为空,已取消" 1
fi
CHARS=$(printf '%s' "$PAYLOAD" | wc -m | tr -d ' ')

# ---- 2. 渲染（失败拦截）----------------------------------------------------
# 若剪贴板无 frontmatter，自动提取第一个 H1 作为 PDF 标题 ——
# QUADERNO 客户端的「标题」列读取 PDF metadata，无标题时文件无法辨认。
PAYLOAD_FINAL="$PAYLOAD"
if ! printf '%s' "$PAYLOAD" | head -5 | grep -q '^---'; then
  TITLE=$(printf '%s' "$PAYLOAD" | grep -m1 '^# ' | sed 's/^# //')
  if [[ -n "$TITLE" ]]; then
    SAFE_TITLE=$(printf '%s' "$TITLE" | sed 's/"/\\"/g')
    PAYLOAD_FINAL="---"
    PAYLOAD_FINAL+=$'\n'"title: \"$SAFE_TITLE\""
    PAYLOAD_FINAL+=$'\n'"---"
    PAYLOAD_FINAL+=$'\n\n'"$PAYLOAD"
  fi
fi
FONTARGS=(); for f in "${FONTS[@]}"; do FONTARGS+=(-V "mainfont=$f"); done
LAYOUTARGS=(
  -V "pagewidth=$PAGE_W" -V "pageheight=$PAGE_H" -V "pagemargin=$PAGE_MARGIN"
  -V "bodysize=$BODY_SIZE" -V "leading=$LEADING"
)
cd "$WORKDIR" || fail "无法进入沙盒 $WORKDIR" 3
if ! printf '%s' "$PAYLOAD_FINAL" \
    | pandoc -f "$MD_FORMAT" --template="$TEMPLATE" "${FONTARGS[@]}" "${LAYOUTARGS[@]}" \
             -o "$OUT" --pdf-engine=typst 2>"$ERRLOG"; then
  fail "渲染失败: $(tail -1 "$ERRLOG" | cut -c1-120)" 2
fi
rm -f "$ERRLOG"

# ---- 2b. 用标题重命名 PDF（QUADERNO 客户端以文件名作显示名）--------------
if [[ -n "${TITLE:-}" ]]; then
  SAFE=$(printf '%s' "$TITLE" | sed 's/[/\\:*?"<>|]/_/g' | cut -c1-60)
  if [[ -n "$SAFE" ]]; then
    TITLE_OUT="$WORKDIR/${SAFE}.pdf"
    mv -f "$OUT" "$TITLE_OUT" 2>/dev/null && OUT="$TITLE_OUT"
  fi
fi

# ---- 3. 定位 QUADERNO 日志（用于真实送达判定）-----------------------------
# 提速：find 全盘走一次要 ~33ms，结果缓存复用；缓存失效才重新定位。
LOGCACHE="${TMPDIR:-/tmp}/.quaderno_logpath"
LOG=""
[[ -f "$LOGCACHE" ]] && LOG=$(<"$LOGCACHE")
if [[ ! -f "$LOG" ]]; then
  LOG=$(find "$HOME/Library/Application Support/Fujitsu" -name logfile.log -type f 2>/dev/null \
        | while read -r p; do print -r -- "$(stat -f '%m' "$p") $p"; done | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -f "$LOG" ]] && print -r -- "$LOG" > "$LOGCACHE"
fi
LOG_BEFORE=0
[[ -f "$LOG" ]] && LOG_BEFORE=$(wc -l < "$LOG" | tr -d ' ')

# ---- 4. 后台静默投递（不抢焦点）-------------------------------------------
open -gj -na "$QUADERNO_APP" --args --print "$OUT"

# ---- 5. 监听真实送达结果 ---------------------------------------------------
# 成功特征：源文件被客户端上传后 unlink（消费）且日志无新 error
# 失败特征：日志新增 device-not-found / cancelled / no-valid-content
# 提速：实测客户端 ~1.24s 就消费完源文件，原先 sleep 1 的粗粒度会白等近 1 秒。
# 改为 0.15s 轮询「源文件是否被消费」（纯 builtin 判断，零 fork）；
# 昂贵的日志扫描（tail+grep 两次 fork）降频到每 ~1s 一次，兼顾灵敏与开销。
POLL=0.15
LOG_EVERY=7                                  # 每 7 轮 ≈ 1s 查一次日志
MAX_ITER=$(( DELIVER_TIMEOUT * 7 ))
RESULT="unknown"
iter=0
while (( iter < MAX_ITER )); do
  if [[ ! -f "$OUT" ]]; then          # 源被消费 = 已被客户端接收
    RESULT="ok"; break
  fi
  if (( iter % LOG_EVERY == 0 )) && [[ -f "$LOG" ]]; then
    if tail -n +$((LOG_BEFORE+1)) "$LOG" 2>/dev/null \
       | grep -qiE 'E_MW_DEVICE_NOT_FOUND|E_MW_CANCELLED|E_MW_UO_SRC_NO_VALID_CONTENT'; then
      RESULT="fail"; break
    fi
  fi
  sleep "$POLL"
  (( iter++ ))
done

case "$RESULT" in
  ok)      notify "Quaderno ✅" "已投递 · ${CHARS} 字" "Tink" ;;
  fail)    fail "设备离线或投递被取消,未送达" 4 ;;
  unknown) notify "Quaderno ⚠️" "已交客户端但未确认送达 (${CHARS} 字),请检查设备连接" "Funk"; rm -f "$OUT" ;;
esac
