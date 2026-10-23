#!/bin/zsh
# =============================================================================
# pair_device.sh · QUADERNO Digital Paper API 一次性配对（交互式）
# -----------------------------------------------------------------------------
# 流程：发现设备 → 请求 PIN（设备屏幕显示）→ 提交 PIN → 写凭据与开关。
# 配对成功后，relay 投递直连设备 API（via=digital-paper-api），不再经过
# 官方 PC App。凭据落 ~/.config/dpt/，一次即可。
#
# 前提：设备已开机并连接（USB 数据线，或与 Mac 同一 Wi-Fi），屏幕已唤醒。
# 也可不用终端：浏览器打开 http://<本机名>.local:8790/pair?token=<token>
# =============================================================================

set -u
SCRIPT_DIR="${0:A:h}"
PY="$SCRIPT_DIR/.venv/bin/python"

[[ -x "$PY" ]] || { echo "缺少 relay/.venv：cd $SCRIPT_DIR && \
python3 -m venv .venv && .venv/bin/pip install dpt-rp1-py"; exit 1; }

echo "→ 扫描设备（约 5 秒）…"
DEVICES=$("$PY" "$SCRIPT_DIR/dp_pair.py" discover)

LIST=$("$PY" - "$DEVICES" <<'PYEOF'
import json, sys
devs = json.loads(sys.argv[1]).get("devices") or []
if not devs:
    print("NONE"); raise SystemExit
for i, d in enumerate(devs, 1):
    print(f"{i}. {d['name']}  {d['addr']}  [{'USB' if d.get('usb') else 'Wi-Fi'}]")
PYEOF
)

if [[ "$LIST" == "NONE" ]]; then
  echo "未发现设备。请确认：数据线已连接 / 设备与 Mac 在同一 Wi-Fi / 设备屏幕已唤醒。"
  exit 2
fi

print -r -- "$LIST"
print -rn -- "选择设备编号（默认 1）: "
read -r N
N=${N:-1}

TARGET=$("$PY" - "$DEVICES" "$N" <<'PYEOF'
import json, sys
devs = json.loads(sys.argv[1]).get("devices") or []
i = int(sys.argv[2]) - 1
if 0 <= i < len(devs):
    d = devs[i]
    print(f"{d['addr']}|{d.get('port', 8443)}|{d.get('reg_port', 8443)}")
PYEOF
)
[[ -z "$TARGET" ]] && { echo "编号无效"; exit 3; }

A=${TARGET%%|*}
REST=${TARGET#*|}
P=${REST%%|*}
RP=${REST##*|}

echo "→ 请求 PIN…"
if ! "$PY" "$SCRIPT_DIR/dp_pair.py" start --addr "$A" --port "$P" --reg-port "$RP"; then
  echo "请求 PIN 失败（见上）。设备是否已唤醒并允许连接？"
  exit 4
fi

print -rn -- "输入 QUADERNO 屏幕显示的 PIN: "
read -r PIN
[[ -z "$PIN" ]] && { echo "未输入 PIN"; exit 5; }

if "$PY" "$SCRIPT_DIR/dp_pair.py" finish --pin "$PIN"; then
  echo "配对完成。此后投递直连设备（响应 via=digital-paper-api）。"
  echo "→ 连通性测试…"
  "$PY" "$SCRIPT_DIR/api_deliver.py" ping \
    && echo "API 直传通道就绪 —— 官方客户端已降级为后备" \
    || echo "ping 失败：设备可能已休眠，唤醒后重试"
else
  echo "配对失败（见上）。可重跑本脚本。"
  exit 6
fi
