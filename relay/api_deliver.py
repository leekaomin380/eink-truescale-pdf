#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
api_deliver.py · QUADERNO Digital Paper API 直传（脱离官方 PC App）
=============================================================================
经 dpt-rp1-py 与设备 8443 API 通信（与 Sony Digital Paper 同源协议），
上传 PDF 到设备文档库。须先运行一次配对（见 relay/pair_device.sh），
凭据落盘 ~/.config/dpt/。

用法（由 iphone_relay.py 以 venv python 调用，也可手动调试）：
  api_deliver.py ping                       设备可达性 + 认证测试 → JSON
  api_deliver.py upload <本地PDF> <设备名>   上传 → JSON

输出一律为单行 JSON：{"ok": bool, ...}
"""

import json
import os
import sys
import warnings

warnings.filterwarnings("ignore")          # 设备使用自签证书，urllib3 会刷告警

AUTH_DIR = os.path.expanduser("~/.config/dpt")


def load_auth():
    """dptrp1 默认凭据：client.dat 存 client_id，key.dat 存私钥。"""
    cid = os.path.join(AUTH_DIR, "client.dat")
    key = os.path.join(AUTH_DIR, "key.dat")
    if not (os.path.isfile(cid) and os.path.isfile(key)):
        return None, None, None
    with open(cid) as f:
        client_id = f.read().strip()
    with open(key) as f:
        key_data = f.read()
    return client_id, key_data, None


def emit(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def connect(addr):
    from dptrp1.dptrp1 import DigitalPaper
    try:
        dp = DigitalPaper(addr=addr, quiet=True)
        client_id, key, _ = load_auth()
        if not client_id:
            emit({"ok": False, "error": "未配对：先运行 relay/pair_device.sh"}, 2)
        resp = dp.authenticate(client_id, key)
        if resp.status_code != 200:
            emit({"ok": False,
                  "error": f"认证失败 HTTP {resp.status_code}（尝试重新配对）"}, 3)
        return dp
    except SystemExit:
        raise
    except Exception as e:
        emit({"ok": False, "error": f"设备连接失败: {type(e).__name__}: {e}"}, 4)


def main():
    args = sys.argv[1:]
    if not args:
        emit({"ok": False, "error": "缺少子命令（ping|upload）"}, 1)

    api_cfg = os.path.expanduser("~/.config/p2q-relay/api.json")
    addr = None
    if os.path.isfile(api_cfg):
        try:
            with open(api_cfg) as f:
                addr = json.load(f).get("addr")
        except Exception:
            pass
    if not addr:
        emit({"ok": False, "error": "缺少 api.json 的 addr（设备 IP 或 Android.local）"}, 1)

    cmd = args[0]
    if cmd == "ping":
        dp = connect(addr)
        info = dp.get_device_info()
        emit({"ok": True, "mode": "api", "device": str(info)[:200]})

    elif cmd == "upload":
        if len(args) < 3:
            emit({"ok": False, "error": "upload 需要 <本地PDF> <设备文件名>"}, 1)
        local, name = args[1], args[2]
        if not os.path.isfile(local):
            emit({"ok": False, "error": f"文件不存在: {local}"}, 1)
        dp = connect(addr)
        remote = f"/Document/{name}"
        with open(local, "rb") as fh:
            dp.upload(fh, remote)
        # 上传后核验：列目录确认对象存在
        docs = dp.list_documents() or {}
        found = any(
            d.get("entry_path") == remote or d.get("entry_name") == name
            for d in (docs if isinstance(docs, list) else docs.get("entry_list", []))
        )
        emit({"ok": True, "mode": "api", "remote": remote,
              "verified": bool(found)})

    else:
        emit({"ok": False, "error": f"未知子命令: {cmd}"}, 1)


if __name__ == "__main__":
    main()
