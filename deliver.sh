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
FONTS=("Charter" "PingFang SC")
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
cd "$WORKDIR" || fail "无法进入沙盒 $WORKDIR" 3
if ! printf '%s' "$PAYLOAD" \
    | pandoc -f markdown --template="$TEMPLATE" "${FONTARGS[@]}" \
             -o "$OUT" --pdf-engine=typst 2>"$ERRLOG"; then
  fail "渲染失败: $(tail -1 "$ERRLOG" | cut -c1-120)" 2
fi
rm -f "$ERRLOG"

# ---- 3. 定位 QUADERNO 日志（用于真实送达判定）-----------------------------
LOG=$(find "$HOME/Library/Application Support/Fujitsu" -name logfile.log -type f 2>/dev/null \
      | while read -r p; do print -r -- "$(stat -f '%m' "$p") $p"; done | sort -rn | head -1 | cut -d' ' -f2-)
LOG_BEFORE=0
[[ -f "$LOG" ]] && LOG_BEFORE=$(wc -l < "$LOG" | tr -d ' ')

# ---- 4. 后台静默投递（不抢焦点）-------------------------------------------
open -gj -na "$QUADERNO_APP" --args --print "$OUT"

# ---- 5. 监听真实送达结果 ---------------------------------------------------
# 成功特征：源文件被客户端上传后 unlink（消费）且日志无新 error
# 失败特征：日志新增 device-not-found / cancelled / no-valid-content
DEADLINE=$(( $(date +%s) + DELIVER_TIMEOUT ))
RESULT="unknown"
while (( $(date +%s) < DEADLINE )); do
  if [[ -f "$LOG" ]]; then
    NEW=$(tail -n +$((LOG_BEFORE+1)) "$LOG" 2>/dev/null)
    if print -r -- "$NEW" | grep -qiE 'E_MW_DEVICE_NOT_FOUND|E_MW_CANCELLED|E_MW_UO_SRC_NO_VALID_CONTENT'; then
      RESULT="fail"; break
    fi
  fi
  if [[ ! -f "$OUT" ]]; then          # 源被消费 = 已被客户端接收
    RESULT="ok"; break
  fi
  sleep 1
done

case "$RESULT" in
  ok)      notify "Quaderno ✅" "已投递 · ${CHARS} 字" "Tink" ;;
  fail)    fail "设备离线或投递被取消,未送达" 4 ;;
  unknown) notify "Quaderno ⚠️" "已交客户端但未确认送达 (${CHARS} 字),请检查设备连接" "Funk"; rm -f "$OUT" ;;
esac
