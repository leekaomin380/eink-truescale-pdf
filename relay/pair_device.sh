#!/bin/zsh
# =============================================================================
# pair_device.sh · QUADERNO Digital Paper API 一次性配对（用户交互式）
# -----------------------------------------------------------------------------
# 前提：设备已开机，Mac 与设备同处一个 Wi-Fi（或 USB 连接且设备为 ECM 模式）。
# 设备屏幕会显示 PIN，输入即完成配对；凭据写入 ~/.config/dpt/，一次即可。
# =============================================================================

set -uo pipefail
SCRIPT_DIR="${0:A:h}"
PY="$SCRIPT_DIR/.venv/bin/python"

[[ -x "$PY" ]] || { echo "❌ 缺少 venv：cd $SCRIPT_DIR && \
/Users/km/.workbuddy/binaries/python/versions/3.13.12/bin/python3 -m venv .venv && \
.venv/bin/pip install dpt-rp1-py"; exit 1; }

# ---- 探测设备地址 -------------------------------------------------------------
echo "→ 正在局域网内寻找 QUADERNO（Bonjour _dp_fujitsu._tcp / _dpt._tcp）…"
ADDR=""
for svc in _dp_fujitsu._tcp _dpt._tcp _digitalpaper._tcp; do
  OUT=$( (dns-sd -B "$svc" . 2>/dev/null & P=$!; sleep 4; kill $P) | awk 'NR>3 {print $7; exit}' )
  if [[ -n "$OUT" ]]; then
    INFO=$( (dns-sd -L "$(echo $OUT | tr -d '\r')" "$svc" local 2>/dev/null & P=$!; sleep 3; kill $P) )
    PORT=$(print -r -- "$INFO" | grep -oE 'port=[0-9]+' | cut -d= -f2)
    HOST=$(print -r -- "$INFO" | grep -oE '[A-Za-z0-9-]+\.local\.' | head -1 | tr -d '.')
    if [[ -n "$HOST" ]]; then ADDR="${HOST}:${PORT:-8443}"; break; fi
  fi
done

if [[ -z "$ADDR" ]]; then
  echo "⚠️  未自动发现设备。请手动输入："
  echo "   · Wi-Fi 模式：设备的 IP（设备端 设置→Wi-Fi 详情可见）"
  echo "   · USB 模式：Android.local（需设备 USB 为 ECM 网络模式）"
  read "ADDR?地址（可带端口，默认 8443）: "
fi

echo "→ 配对目标：$ADDR"
echo "→ 请看向 QUADERNO 屏幕，把显示的 PIN 输入到提示中…"
"$PY" -m dptrp1 --addr "$ADDR" register

if [[ -f "$HOME/.config/dpt/client.dat" ]]; then
  echo "✅ 配对完成，凭据已写入 ~/.config/dpt/"
  echo "→ 连通性测试…"
  mkdir -p "$HOME/.config/p2q-relay"
  # 记录地址供 relay 使用（去端口，API 基址固定 :8443）
  print -r -- "{\"enabled\": true, \"addr\": \"${ADDR%%:*}\"}" \
    > "$HOME/.config/p2q-relay/api.json"
  "$PY" "$SCRIPT_DIR/api_deliver.py" ping \
    && echo "✅ API 直传通道就绪 —— relay 将优先走 API，官方客户端自动降级为后备" \
    || echo "❌ ping 失败，检查设备与 Mac 是否同网段"
else
  echo "❌ 配对未完成（未生成凭据文件）"
  exit 1
fi
