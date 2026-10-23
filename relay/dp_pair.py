#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dp_pair.py · QUADERNO Digital Paper API 配对（两阶段，免终端交互）
=============================================================================
与 Sony Digital Paper 同源的注册协议（/register/pin → hash → ca → 注册），
把 dptrp1 的一体式交互流程拆成两段，使 PIN 可从网页/快捷指令提交：

  dp_pair.py discover                          → 列出局域网/USB 上发现的设备
  dp_pair.py start --addr HOST [--port 8443]   → 请求 PIN（设备屏幕显示 4-8 位）
  dp_pair.py finish --pin 1234                 → 提交 PIN，写凭据与 api.json

凭据落盘（与 dptrp1 约定一致）：
  ~/.config/dpt/deviceid.dat   客户端 ID
  ~/.config/dpt/privatekey.dat RSA 私钥（PEM）
  ~/.config/dpt/cert.pem       设备 CA 证书
开关落盘：
  ~/.config/p2q-relay/api.json {"enabled": true, "addr": ..., "api_port": ..., "reg_port": ...}

输出一律单行 JSON：{"ok": bool, ...}
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import uuid
import warnings

warnings.filterwarnings("ignore")          # 设备自签证书

from Crypto.Cipher import AES
from Crypto.Hash import SHA256
from Crypto.Hash.HMAC import HMAC
from Crypto.PublicKey import RSA
from pbkdf2 import PBKDF2
import requests

from dptrp1.pyDH import DiffieHellman

AUTH_DIR = os.path.expanduser("~/.config/dpt")
RELAY_DIR = os.path.expanduser("~/.config/p2q-relay")
STATE_FILE = os.path.join(RELAY_DIR, "pair_state.json")
API_CFG = os.path.join(RELAY_DIR, "api.json")


# ---- 加密原语（与 dptrp1 实现一致）------------------------------------------
def _pad(b, k=16):
    l = len(b)
    return b + (k - l % k) * bytes([k - l % k])


def _unpad(b):
    return b[: -b[-1]]


def _wrap(data, auth_key, key_wrap_key):
    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(data)
    kwa = hmac.digest()[:8]
    iv = os.urandom(16)
    cipher = AES.new(key_wrap_key, AES.MODE_CBC, iv)
    return cipher.encrypt(_pad(data + kwa)) + iv


def _unwrap(data, auth_key, key_wrap_key):
    iv = data[-16:]
    cipher = AES.new(key_wrap_key, AES.MODE_CBC, iv)
    unwrapped = _unpad(cipher.decrypt(data[:-16]))
    kwa, body = unwrapped[-8:], unwrapped[:-8]
    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(body)
    if kwa != hmac.digest()[:8]:
        raise ValueError("kwa 校验失败")
    return body


def emit(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def _b64e(b):
    return base64.b64encode(b).decode()


def _b64d(s):
    return base64.b64decode(s)


# ---- 注册端点会话 -----------------------------------------------------------
class RegSession:
    """注册走 HTTP 8080（USB ECM 通告的端口）；主 API 走 HTTPS 8443。

    IPv6 link-local 的 zone id 在 URL 里必须写成 %25enN（RFC 6874），
    否则 urllib3 会报 InvalidURL。
    """

    def __init__(self, host, reg_port=8080):
        self.host = host.replace("%25", "%")
        self.reg_port = int(reg_port)
        self.s = requests.Session()
        self.s.verify = False

    def _url_host(self):
        return self.host.replace("%", "%25")

    def req(self, method, endpoint, data=None):
        url = f"http://{self._url_host()}:{self.reg_port}{endpoint}"
        return self.s.request(method, url, json=data, timeout=20)


# ---- 设备发现 ---------------------------------------------------------------
def _dns_sd(args, seconds=1.2):
    """跑一次 dns-sd 并收集输出。

    dns-sd 无超时参数且长时间静默，必须用非阻塞读，否则 readline 会挂住。
    """
    import time
    p = subprocess.Popen(["dns-sd", *args],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    os.set_blocking(p.stdout.fileno(), False)
    out, end = [], time.time() + seconds
    while time.time() < end:
        line = p.stdout.readline()
        if line:
            out.append(line.rstrip("\n"))
        else:
            time.sleep(0.03)
    p.kill()
    p.wait()
    return out


def _active_ifaces():
    """活跃的 en* 接口 [(ifindex, name)]，排除 utun/awdl/llw 等虚拟接口。"""
    import socket as _socket
    res, seen = [], set()
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return res
    for line in out.splitlines():
        m = re.match(r"^(en\d+): flags=\w+<([^>]*)>", line)
        if not m:
            continue
        name, flags = m.group(1), m.group(2)
        if "UP" not in flags or "RUNNING" not in flags or name in seen:
            continue
        try:
            idx = _socket.if_nametoindex(name)
        except OSError:
            continue
        seen.add(name)
        res.append((idx, name))
    return res


def _scan_iface(idx, iname):
    """在单个接口上浏览并解析设备，返回候选列表。"""
    out = []
    lines = _dns_sd(["-B", "_dp_fujitsu._tcp", ".", str(idx)], 1.2)
    names = []
    for ln in lines:
        if "_dp_fujitsu._tcp." in ln and "STARTING" not in ln and "Timestamp" not in ln:
            parts = ln.split()
            if len(parts) >= 7:
                names.append(" ".join(parts[6:]))
    for name in names:
        lookup = _dns_sd(["-L", name, "_dp_fujitsu._tcp", "local", str(idx)], 1.2)
        host, port = None, 8443
        for ln in lookup:
            m = re.search(r"can be reached at (.+?):(\d+)", ln)
            if m:
                host, port = m.group(1).rstrip("."), int(m.group(2))
                break
        if not host:
            continue
        addrs = []
        # -G 不接受接口索引，只能全局解析（返回项自带 %enN zone）
        for rec in _dns_sd(["-G", "v4v6", host if host.endswith(".") else host + "."], 1.5):
            m = re.search(r"\s([0-9a-fA-F:.]+(?:%[a-zA-Z0-9]+)?)\s+\d+\s*$", rec)
            if m and m.group(1) not in ("0.0.0.0", "::"):
                addrs.append(m.group(1))
        if not addrs:
            addrs = [host]
        for a in addrs:
            zone = None
            if a.lower().startswith("fe80"):
                if "%" in a:
                    zone = a.split("%", 1)[1]
                else:
                    a = f"{a}%{iname}"
                    zone = iname
                dev_addr = f"[{a}]"
            else:
                dev_addr = a
            out.append({
                "name": name,
                "host": host,
                "addr": dev_addr,
                "port": 8443,
                "reg_port": 8080 if zone else 8443,
                "usb": bool(zone),
                "iface": zone or iname,
            })
    return out


def discover():
    """并发在各活跃接口上做 mDNS 浏览，返回可连地址候选。

    USB ECM 模式下设备只通告 IPv6 link-local（Android.local），
    Wi-Fi 模式下通常有 IPv4，故两者都收。
    """
    import concurrent.futures
    ifaces = _active_ifaces() or [(0, "en0")]
    found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(ifaces)) as ex:
        for res in ex.map(lambda t: _scan_iface(*t), ifaces):
            found.extend(res or [])
    seen, uniq = set(), []
    for f in found:
        key = (f["addr"], f["reg_port"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(f)
    return uniq


def _ifname(idx):
    """由 dns-sd 的接口索引（link#N）反查接口名（enN）。"""
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            m = re.match(rf"^(en\d+):.*link#(\d+)", line)
            if m and m.group(2) == str(idx):
                return m.group(1)
    except Exception:
        pass
    return None


def _save_state(d):
    os.makedirs(RELAY_DIR, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(d, f)
    os.chmod(STATE_FILE, 0o600)


def _load_state():
    if not os.path.isfile(STATE_FILE):
        return None
    with open(STATE_FILE) as f:
        return json.load(f)


# ---- 阶段一：请求 PIN -------------------------------------------------------
def do_start(addr, reg_port, api_port):
    sess = RegSession(addr, reg_port)
    try:
        sess.req("PUT", "/register/cleanup")
        r = sess.req("POST", "/register/pin")
        if r.status_code != 200:
            emit({"ok": False,
                  "error": f"请求 PIN 失败 HTTP {r.status_code}（设备是否已开启 API/已连接？）"}, 2)
        m1 = r.json()
    except requests.exceptions.RequestException as e:
        emit({"ok": False, "error": f"连接设备失败: {type(e).__name__}: {e}"}, 3)

    n1 = _b64d(m1["a"])
    mac = _b64d(m1["b"])
    yb = _b64d(m1["c"])
    yb_int = int.from_bytes(yb, "big")
    n2 = os.urandom(16)

    dh = DiffieHellman()
    ya = b"\x00" + dh.gen_public_key().to_bytes(256, "big")
    zz = dh.gen_shared_key(yb_int).to_bytes(256, "big")

    derived = PBKDF2(passphrase=zz, salt=n1 + mac + n2, iterations=10000,
                     digestmodule=SHA256).read(48)
    auth_key, key_wrap_key = derived[:32], derived[32:]

    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(n1 + mac + yb + n1 + n2 + mac + ya)
    m2hmac = hmac.digest()

    m2 = {"a": _b64e(n1), "b": _b64e(n2), "c": _b64e(mac),
          "d": _b64e(ya), "e": _b64e(m2hmac)}

    try:
        r = sess.req("POST", "/register/hash", data=m2)
        if r.status_code != 200:
            emit({"ok": False, "error": f"hash 交换失败 HTTP {r.status_code}"}, 4)
        m3 = r.json()
    except requests.exceptions.RequestException as e:
        emit({"ok": False, "error": f"hash 交换异常: {e}"}, 4)

    if _b64d(m3.get("a", "")) != n2:
        emit({"ok": False, "error": "设备返回的 N2 不匹配"}, 5)
    e_hash = _b64d(m3["b"])
    m3hmac = _b64d(m3["e"])
    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(n1 + n2 + mac + ya + m2hmac + n2 + e_hash)
    if m3hmac != hmac.digest():
        emit({"ok": False, "error": "M3 HMAC 校验失败"}, 5)

    _save_state({
        "addr": addr, "api_port": api_port, "reg_port": reg_port,
        "n1": _b64e(n1), "n2": _b64e(n2), "mac": _b64e(mac),
        "ya": _b64e(ya), "yb": _b64e(yb), "auth_key": _b64e(auth_key),
        "key_wrap_key": _b64e(key_wrap_key), "m2hmac": _b64e(m2hmac),
        "e_hash": _b64e(e_hash), "m3hmac": _b64e(m3hmac),
    })
    emit({"ok": True, "pin_required": True, "addr": addr,
          "hint": "请查看 QUADERNO 屏幕显示的 PIN，然后提交"})


# ---- 阶段二：提交 PIN 完成注册 ----------------------------------------------
def do_finish(pin):
    st = _load_state()
    if not st:
        emit({"ok": False, "error": "没有待完成的配对会话，请先请求 PIN"}, 2)

    b = _b64d
    n1, n2, mac = b(st["n1"]), b(st["n2"]), b(st["mac"])
    ya, yb = b(st["ya"]), b(st["yb"])
    auth_key, key_wrap_key = b(st["auth_key"]), b(st["key_wrap_key"])
    m2hmac, e_hash, m3hmac = b(st["m2hmac"]), b(st["e_hash"]), b(st["m3hmac"])

    sess = RegSession(st["addr"], st["reg_port"])

    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(str(pin).strip().encode())
    psk = hmac.digest()

    rs = os.urandom(16)
    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(rs + psk + yb + ya)
    r_hash = hmac.digest()
    wrapped_rs = _wrap(rs, auth_key, key_wrap_key)

    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(n2 + e_hash + m3hmac + n1 + r_hash + wrapped_rs)
    m4 = {"a": _b64e(n1), "b": _b64e(r_hash),
          "d": _b64e(wrapped_rs), "e": _b64e(hmac.digest())}

    try:
        r = sess.req("POST", "/register/ca", data=m4)
        if r.status_code != 200:
            emit({"ok": False, "error": f"PIN 校验失败 HTTP {r.status_code}（PIN 是否正确？）"}, 3)
        m5 = r.json()
    except requests.exceptions.RequestException as e:
        emit({"ok": False, "error": f"证书交换异常: {e}"}, 3)

    if _b64d(m5.get("a", "")) != n2:
        emit({"ok": False, "error": "设备返回的 N2 不匹配"}, 4)
    wrapped_cert = _b64d(m5["d"])
    m5hmac = _b64d(m5["e"])
    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(n1 + r_hash + wrapped_rs + b(m4["e"]) + n2 + wrapped_cert)
    if hmac.digest() != m5hmac:
        emit({"ok": False, "error": "M5 HMAC 校验失败"}, 4)

    cert_blob = _unwrap(wrapped_cert, auth_key, key_wrap_key)
    es, cert = cert_blob[:16], cert_blob[16:]

    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(es + psk + yb + ya)
    if hmac.digest() != e_hash:
        emit({"ok": False, "error": "设备认证材料校验失败（PIN 可能错误）"}, 5)

    new_key = RSA.generate(2048, e=65537)
    key_pub = new_key.publickey().exportKey("PEM")
    device_id = str(uuid.uuid4())

    wrapped = _wrap(device_id.encode() + key_pub, auth_key, key_wrap_key)
    hmac = HMAC(auth_key, digestmod=SHA256)
    hmac.update(n2 + wrapped_cert + m5hmac + n1 + wrapped)
    m6 = {"a": _b64e(n1), "d": _b64e(wrapped), "e": _b64e(hmac.digest())}

    try:
        r = sess.req("POST", "/register", data=m6)
        if r.status_code != 200:
            emit({"ok": False, "error": f"注册提交失败 HTTP {r.status_code}"}, 6)
        sess.req("PUT", "/register/cleanup")
    except requests.exceptions.RequestException as e:
        emit({"ok": False, "error": f"注册提交异常: {e}"}, 6)

    os.makedirs(AUTH_DIR, exist_ok=True)
    with open(os.path.join(AUTH_DIR, "deviceid.dat"), "w") as f:
        f.write(device_id)
    with open(os.path.join(AUTH_DIR, "privatekey.dat"), "w") as f:
        f.write(new_key.exportKey("PEM").decode())
    with open(os.path.join(AUTH_DIR, "cert.pem"), "wb") as f:
        f.write(cert)
    os.chmod(os.path.join(AUTH_DIR, "privatekey.dat"), 0o600)

    os.makedirs(RELAY_DIR, exist_ok=True)
    with open(API_CFG, "w") as f:
        json.dump({"enabled": True, "addr": st["addr"],
                   "api_port": st["api_port"], "reg_port": st["reg_port"]}, f)

    try:
        os.remove(STATE_FILE)
    except OSError:
        pass

    emit({"ok": True, "paired": True, "client_id": device_id,
          "addr": st["addr"], "api_port": st["api_port"]})


def do_forget():
    for name in ("api.json", "pair_state.json"):
        p = os.path.join(RELAY_DIR, name)
        if os.path.isfile(p):
            os.remove(p)
    emit({"ok": True, "forgot": True})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["discover", "start", "finish", "forget"])
    ap.add_argument("--addr", default=None)
    ap.add_argument("--port", type=int, default=8443, help="主 API 端口")
    ap.add_argument("--reg-port", type=int, default=8080, help="注册端口")
    ap.add_argument("--pin", default=None)
    a = ap.parse_args()

    if a.cmd == "discover":
        emit({"ok": True, "devices": discover()})
    if a.cmd == "start":
        if not a.addr:
            emit({"ok": False, "error": "start 需要 --addr"}, 1)
        do_start(a.addr, a.reg_port, a.port)
    if a.cmd == "finish":
        if not a.pin:
            emit({"ok": False, "error": "finish 需要 --pin"}, 1)
        do_finish(a.pin)
    if a.cmd == "forget":
        do_forget()


if __name__ == "__main__":
    main()
