#!/bin/zsh
# =============================================================================
# deliver.sh  ·  剪贴板 Markdown → Quaderno 墨水屏 · 零 GUI 投递管道
# -----------------------------------------------------------------------------
# 用法：绑到全局热键（Raycast Script Command / macOS 快捷指令），无参运行即可。
# 流程：抓剪贴板 → pandoc+typst 渲染 PDF → open -gj 后台投递 → 监听日志给出真实反馈
# 设计依据见项目 README。作者约定的铁律：强制 /tmp 沙盒、指令与数据物理隔离。
# =============================================================================

# ---- 配置区（未来只改这里）------------------------------------------------
# 字体 fallback 列表：第一个覆盖拉丁，后续覆盖中文/其它。加字体只需往数组追加。
# 中英统一无衬线，质感一致（对照 Bear 导出效果调校）。
FONTS=("Helvetica Neue" "PingFang SC")

# 版面：按 Quaderno A5 显示区物理尺寸出纸，实现 1:1 显示、零缩放、零留边。
# 依据 FMVDP51 规格 1404×1872 px @ 227dpi → 157.1mm × 209.5mm（宽高比 3:4）。
# 若改用 A4 机型，只需替换这两个值为该机型显示区尺寸。
PAGE_W="157.1mm"
PAGE_H="209.5mm"
PAGE_MARGIN="10mm"                   # 屏幕阅读无需装订位，窄边距换取更大版心
BODY_SIZE="10pt"                     # 1:1 已实测确认（尺子量 100mm 基准线正好 100mm），
                                     # 故此值即屏幕上的真实物理字号。pt = point = 1/72 英寸。
LEADING="0.85em"                     # 行距，墨水屏宜宽松

# Markdown 方言：载荷是"任意粘贴的对话文本"，必须关掉两个会误伤的默认扩展：
#   -citations        : 否则 "@227dpi"/"@某人"/邮箱 会被当文献引用 → typst 报
#                       "the document does not contain a bibliography" 直接渲染失败
#   -tex_math_dollars : 否则正文里的 $PATH / $1 / $mainfont$ 会被当数学公式吃掉
MD_FORMAT="markdown-citations-tex_math_dollars"

QUADERNO_APP="/Applications/QUADERNO PC App.app"
WORKDIR="/tmp"                       # 铁律：只读根目录规避，pandoc 临时文件须落沙盒
DELIVER_TIMEOUT=15                   # 监听送达结果的最长秒数
# ---------------------------------------------------------------------------

set -uo pipefail

# 铁律①：强制 UTF-8 locale。快捷指令等最小化环境常不带 locale，
# 缺失时 pandoc 会把 UTF-8 中文误判为 latin1 → 设备上一片乱码。
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# 铁律②：快捷指令给的 PATH 只有 /usr/bin:/bin，不含 Homebrew。
# 不补 /opt/homebrew/bin，热键触发时会找不到 pandoc/typst。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="${0:A:h}"
TEMPLATE="$SCRIPT_DIR/deliver.typ"
OUT="$WORKDIR/quaderno_delivery_$$.pdf"     # PID 命名，隔离并发
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
FONTARGS=(); for f in "${FONTS[@]}"; do FONTARGS+=(-V "mainfont=$f"); done
LAYOUTARGS=(
  -V "pagewidth=$PAGE_W" -V "pageheight=$PAGE_H" -V "pagemargin=$PAGE_MARGIN"
  -V "bodysize=$BODY_SIZE" -V "leading=$LEADING"
)
cd "$WORKDIR" || fail "无法进入沙盒 $WORKDIR" 3
if ! printf '%s' "$PAYLOAD" \
    | pandoc -f "$MD_FORMAT" --template="$TEMPLATE" "${FONTARGS[@]}" "${LAYOUTARGS[@]}" \
             -o "$OUT" --pdf-engine=typst 2>"$ERRLOG"; then
  fail "渲染失败: $(tail -1 "$ERRLOG" | cut -c1-120)" 2
fi
rm -f "$ERRLOG"

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
