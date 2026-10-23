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
    """凭据由 dp_pair.py 写入（与 dptrp1 约定一致：deviceid.dat / privatekey.dat）。"""
    cid = os.path.join(AUTH_DIR, "deviceid.dat")
    key = os.path.join(AUTH_DIR, "privatekey.dat")
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


def make_client(addr, api_port=8443):
    """DigitalPaper 的 base_url 只按「addr 是否含 :」猜端口，无法表达
    IPv6 zone + 自定义端口，故以子类固定 URL（USB ECM 与 Wi-Fi 都能用）。"""
    from dptrp1.dptrp1 import DigitalPaper

    class RelayDigitalPaper(DigitalPaper):
        def __init__(self, host, port):
            self.host = host.replace("%25", "%")
            self.api_port = port
            self.session = __import__("requests").Session()
            self.session.verify = False
            self.assume_yes = True
            self.addr = host

        @property
        def base_url(self):
            # IPv6 zone 在 URL 中须写作 %25enN（RFC 6874）
            return f"https://{self.host.replace('%', '%25')}:{self.api_port}"

    return RelayDigitalPaper(addr, api_port)


def connect(addr, api_port=8443):
    try:
        dp = make_client(addr, api_port)
        client_id, key, _ = load_auth()
        if not client_id:
            emit({"ok": False, "error": "未配对：运行 relay/pair_device.sh 或打开 http://<本机>.local:8790/pair"}, 2)
        resp = dp.authenticate(client_id, key)
        if resp.status_code != 200:
            emit({"ok": False,
                  "error": f"认证失败 HTTP {resp.status_code}（凭据失效，需重新配对）"}, 3)
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
    addr, api_port = None, 8443
    if os.path.isfile(api_cfg):
        try:
            with open(api_cfg) as f:
                cfg = json.load(f)
            addr = cfg.get("addr")
            api_port = int(cfg.get("api_port") or 8443)
        except Exception:
            pass
    if not addr:
        emit({"ok": False, "error": "缺少 api.json 的 addr（先配对：/pair）"}, 1)

    cmd = args[0]
    if cmd == "ping":
        dp = connect(addr, api_port)
        info = dp.get_device_info()
        emit({"ok": True, "mode": "api", "device": str(info)[:200]})

    elif cmd == "upload":
        if len(args) < 3:
            emit({"ok": False, "error": "upload 需要 <本地PDF> <设备文件名>"}, 1)
        local, name = args[1], args[2]
        if not os.path.isfile(local):
            emit({"ok": False, "error": f"文件不存在: {local}"}, 1)
        dp = connect(addr, api_port)
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
