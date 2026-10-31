#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iphone_relay.py · iPhone → Quaderno 中继服务
=============================================================================
iPhone 快捷指令通过 HTTP 把文本或文章 URL 交给本服务；本服务调用 book.sh
按 QUADERNO 显示区物理尺寸渲染 PDF，再经官方 QUADERNO PC App 投递到设备，
并把真实送达结果回传给 iPhone。

设计原则（与仓库既有约定一致）：
  1. 本服务只是一层壳。渲染一律调用 book.sh，不重复实现排版逻辑。
  2. 仅用 Python 标准库，无 pip 依赖。
  3. 指令与数据物理隔离：所有中间产物落在 /tmp/p2q_relay。
  4. 送达判定与 deliver.sh 同源：源文件被客户端消费 = 已接收；
     客户端日志出现 E_MW_* 错误 = 失败。

接口：
  GET  /health                     健康检查
  POST /deliver                    投递。JSON:
                                   {"type": "text"|"url",
                                    "content": "<markdown 文本>",   # type=text
                                    "url": "https://...",          # type=url
                                    "title": "可选标题",
                                    "plain": true|false(默认 true)}
  鉴权：请求头 X-Relay-Token:<token>，token 首次启动自动生成于
        ~/.config/p2q-relay/token
启动：python3 iphone_relay.py [--port 8790] [--bind 0.0.0.0]
"""

import argparse
import hashlib
import html as html_mod
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

# ---- 路径与环境 --------------------------------------------------------------
REPO = Path(__file__).resolve().parent.parent
BOOK_SH = REPO / "book.sh"
CONFIG_SH = REPO / "config.sh"
QUADERNO_APP = "/Applications/QUADERNO PC App.app"
WORK = Path(tempfile.gettempdir()) / "p2q_relay"
WORK.mkdir(exist_ok=True)
TOKEN_FILE = Path.home() / ".config" / "p2q-relay" / "token"
API_CFG = Path.home() / ".config" / "p2q-relay" / "api.json"
VENV_PY = REPO / "relay" / ".venv" / "bin" / "python"
API_DELIVER = REPO / "relay" / "api_deliver.py"
DP_PAIR = REPO / "relay" / "dp_pair.py"

ENV = {
    **os.environ,
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "PATH": "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", ""),
}
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

DELIVER_LOCK = threading.Lock()   # 官方客户端并发投递会互相踩踏，串行化
DELIVER_TIMEOUT_S = 45            # 中继场景以短文档为主；未确认时尽快返回，避免快捷指令久等

# 客户端日志中的失败特征（与 deliver.sh 同源）
LOG_ERROR_PAT = re.compile(
    r"E_MW_DEVICE_NOT_FOUND|E_MW_CANCELLED|E_MW_UO_SRC_NO_VALID_CONTENT", re.I)


# ---- 配置读取（单一事实来源 config.sh）---------------------------------------
def read_config():
    txt = CONFIG_SH.read_text(encoding="utf-8")
    def grab(key, default):
        m = re.search(rf'^{key}="([^"]*)"', txt, re.M)
        return m.group(1) if m else default
    fonts = re.search(r'^FONTS=\((.*?)\)', txt, re.M)
    font_list = re.findall(r'"([^"]+)"', fonts.group(1)) if fonts else []
    return {
        "page_w": grab("PAGE_W", "157.1mm"),
        "page_h": grab("PAGE_H", "209.5mm"),
        "margin": grab("PAGE_MARGIN", "14mm"),
        "size": grab("BODY_SIZE", "10.5pt"),
        "leading": grab("LEADING", "0.85em"),
        "lang": grab("DOC_LANG", "zh"),
        "fonts": font_list,
    }


def load_token():
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    tok = secrets.token_hex(16)
    TOKEN_FILE.write_text(tok + "\n", encoding="utf-8")
    TOKEN_FILE.chmod(0o600)
    return tok


# ---- 渲染（调 book.sh，不重复实现）-------------------------------------------
def render(src: Path, out: Path, cfg, plain=True):
    cmd = [str(BOOK_SH), str(src), "-o", str(out),
           "--size", cfg["size"], "--margin", cfg["margin"],
           "--leading", cfg["leading"], "--lang", cfg["lang"],
           "--font", ",".join(cfg["fonts"]),
           "--page", cfg["page_w"], cfg["page_h"]]
    if plain:
        cmd.append("--plain")
    return subprocess.run(cmd, capture_output=True, text=True, env=ENV,
                          timeout=600)


def pdf_pages(pdf: Path):
    try:
        data = pdf.read_bytes()
        counts = [int(x) for x in re.findall(rb"/Count\s+(\d+)", data)]
        return max(counts) if counts else 0
    except Exception:
        return 0


# ---- 投递路径 1：Digital Paper API 直传（不经官方客户端）----------------------
# 配对后 api.json enabled=true 时启用；返回 None 表示该路径不可用（走后备）。
def deliver_via_api(pdf: Path, title: str):
    if not (API_CFG.exists() and VENV_PY.exists() and API_DELIVER.exists()):
        return None
    try:
        cfg = json.loads(API_CFG.read_text(encoding="utf-8"))
        if not cfg.get("enabled"):
            return None
    except Exception:
        return None
    safe = re.sub(r'[/\\:*?"<>|]', "_", title)[:60] or "document"
    try:
        r = subprocess.run(
            [str(VENV_PY), str(API_DELIVER), "upload", str(pdf), f"{safe}.pdf"],
            capture_output=True, text=True, env=ENV, timeout=90)
        out = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
        if out.get("ok"):
            return "delivered", "API 直传完成" + ("（已核验）" if out.get("verified") else ""), "digital-paper-api"
        return "api-error", out.get("error", "API 上传失败"), "digital-paper-api"
    except subprocess.TimeoutExpired:
        return "api-error", "API 上传超时", "digital-paper-api"
    except Exception as e:
        return "api-error", f"API 路径异常: {e}", "digital-paper-api"


# ---- 配对（Digital Paper API，脱离官方 PC App）-------------------------------
def _dp_pair(*args, timeout=240):
    """调用 venv 里的 dp_pair.py（Crypto 依赖只在 venv 内）。"""
    if not (VENV_PY.exists() and DP_PAIR.exists()):
        return {"ok": False, "error": "缺少 relay/.venv（dpt-rp1-py 未安装）"}
    try:
        r = subprocess.run([str(VENV_PY), str(DP_PAIR), *args],
                           capture_output=True, text=True, env=ENV, timeout=timeout)
        lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
        if not lines:
            return {"ok": False, "error": (r.stderr or "配对脚本无输出")[-300:]}
        return json.loads(lines[-1])
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "配对操作超时"}
    except Exception as e:
        return {"ok": False, "error": f"配对调用失败: {type(e).__name__}: {e}"}


def api_state():
    """当前 API 直传是否已启用。"""
    try:
        cfg = json.loads(API_CFG.read_text(encoding="utf-8"))
        return bool(cfg.get("enabled")), cfg.get("addr", "")
    except Exception:
        return False, ""


PAIR_HTML = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>配对 QUADERNO</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; font:16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
         background:#f6f7f9; color:#1c1c1e; }
  main { max-width:520px; margin:0 auto; padding:28px 20px 60px; }
  h1 { font-size:22px; margin:0 0 6px; }
  .hint { color:#6b6f76; font-size:14px; margin:0 0 22px; }
  .state { display:inline-block; padding:6px 12px; border-radius:8px; background:#e9ecf2;
           font-size:14px; margin-bottom:22px; }
  label { display:block; font-size:13px; color:#6b6f76; margin:18px 0 6px; }
  input { width:100%; box-sizing:border-box; padding:11px 12px; font-size:16px;
          border:1px solid #d3d7de; border-radius:10px; background:#fff; color:inherit; }
  button { width:100%; margin-top:12px; padding:12px; font-size:16px; border:0;
           border-radius:10px; background:#0a84ff; color:#fff; }
  button.dev { background:#fff; color:#1c1c1e; border:1px solid #d3d7de;
               text-align:left; font-size:15px; }
  #log { margin-top:20px; white-space:pre-wrap; font-size:14px; color:#3c4149; }
  @media (prefers-color-scheme: dark) {
    body { background:#121214; color:#f2f2f7; }
    .state { background:#242428; }
    input, button.dev { background:#1c1c1f; color:#f2f2f7; border-color:#3a3a3e; }
  }
</style></head>
<body><main>
<h1>配对 QUADERNO</h1>
<p class="hint">配对一次即可：此后投递直连设备 API，不再经过官方 PC App。设备需已连接（USB 或同一 Wi-Fi）。</p>
<div class="state" id="state">状态读取中…</div>
<label>访问令牌</label>
<input id="token" value="__TOKEN__" placeholder="~/.config/p2q-relay/token 的内容">
<button onclick="discover()">扫描设备</button>
<div id="devices"></div>
<div id="pinbox" hidden>
  <label>设备屏幕显示的 PIN</label>
  <input id="pin" inputmode="numeric" autocomplete="one-time-code" placeholder="4-8 位数字">
  <button onclick="finish()">提交 PIN</button>
</div>
<pre id="log"></pre>
</main>
<script>
var chosen = null;
function T() { return document.getElementById('token').value.trim(); }
function log(s) { document.getElementById('log').textContent = s; }
async function api(path, body) {
  const r = await fetch(path, {method:'POST',
    headers:{'Content-Type':'application/json','X-Relay-Token':T()},
    body: JSON.stringify(body || {})});
  return await r.json();
}
async function discover() {
  log('扫描中…');
  const j = await api('/pair/discover');
  if (!j.ok) { log(j.error || '扫描失败'); return; }
  const box = document.getElementById('devices'); box.innerHTML = '';
  if (!j.devices.length) { log('未发现设备：确认 USB 已连接且设备屏幕已唤醒，或设备与 Mac 在同一 Wi-Fi。'); return; }
  j.devices.forEach(function(d) {
    const b = document.createElement('button');
    b.className = 'dev';
    b.textContent = d.name + ' · ' + d.addr + (d.usb ? '（USB）' : '（Wi-Fi）');
    b.onclick = function() { start(d); };
    box.appendChild(b);
  });
  log('发现 ' + j.devices.length + ' 个设备，点选一个。');
}
async function start(d) {
  chosen = d; log('已请求 PIN，请看设备屏幕…');
  const j = await api('/pair/start', {addr:d.addr, port:d.port, reg_port:d.reg_port});
  if (!j.ok) { log(j.error || '请求失败'); return; }
  document.getElementById('pinbox').hidden = false;
  log('设备屏幕显示 PIN 后，在此输入并提交。');
}
async function finish() {
  const pin = document.getElementById('pin').value.trim();
  if (!pin) { log('请输入 PIN'); return; }
  log('提交中…');
  const j = await api('/pair/finish', {pin:pin});
  log(j.ok ? ('配对完成：' + j.addr + '，此后投递直连设备。') : (j.error || '配对失败'));
  if (j.ok) { document.getElementById('pinbox').hidden = true; refresh(); }
}
async function refresh() {
  const r = await fetch('/pair/status'); const j = await r.json();
  document.getElementById('state').textContent =
    j.paired ? ('已配对 · ' + j.addr) : '未配对（投递将经官方 PC App）';
}
refresh();
</script>
</body></html>
"""


# ---- 投递路径 2（后备）：官方 QUADERNO PC App ---------------------------------
# 送达判定与 deliver.sh 同源：源文件被客户端消费 = 已接收；日志 E_MW_* = 失败。
def find_client_log():
    base = Path.home() / "Library" / "Application Support" / "Fujitsu"
    best, best_mtime = None, -1
    for p in base.rglob("logfile.log"):
        try:
            m = p.stat().st_mtime
            if m > best_mtime:
                best, best_mtime = p, m
        except OSError:
            pass
    return best


def deliver_pdf(pdf: Path, title: str):
    """返回 (status, detail)。status ∈ delivered / offline / cancelled / unconfirmed"""
    app = Path(QUADERNO_APP)
    if not app.exists():
        return "client-missing", "未找到 QUADERNO PC App", "official-client"
    safe = re.sub(r'[/\\:*?"<>|]', "_", (title or "deliver"))[:60] or "deliver"
    copy = WORK / f"{safe}.pdf"
    shutil.copy(pdf, copy)

    log = find_client_log()
    before = 0
    if log:
        try:
            before = len(log.read_text(encoding="utf-8", errors="ignore").splitlines())
        except OSError:
            log = None

    subprocess.run(["open", "-gj", "-na", QUADERNO_APP, "--args",
                    "--print", str(copy)], env=ENV, check=False)

    deadline = time.time() + DELIVER_TIMEOUT_S
    while time.time() < deadline:
        if not copy.exists():                      # 源被消费 = 客户端已接收
            return "delivered", "客户端已接收", "official-client"
        if log:
            try:
                new_tail = "".join(log.read_text(encoding="utf-8",
                                                 errors="ignore")
                                   .splitlines(keepends=True)[before:])
                m = LOG_ERROR_PAT.search(new_tail)
                if m:
                    token = m.group(0).upper()
                    if "DEVICE_NOT_FOUND" in token:
                        return "offline", "设备离线或未连接", "official-client"
                    if "CANCELLED" in token:
                        return "cancelled", "投递被取消", "official-client"
                    return "failed", f"客户端报错 {token}", "official-client"
            except OSError:
                pass
        time.sleep(0.25)
    try:
        copy.unlink()
    except OSError:
        pass
    return "unconfirmed", "超时未确认，请检查客户端与设备连接", "official-client"


# ---- 网页抓取与正文抽取 -------------------------------------------------------
def fetch_url(url: str, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def abs_img(src: str, base: str):
    src = src.strip()
    if src.startswith("//"):
        return "https:" + src
    if src.startswith("http"):
        return src
    return urllib.parse.urljoin(base, src)


class ArticleExtractor(HTMLParser):
    """从 HTML 中抽取公众号正文 / <article> / 兜底正文，输出简化 HTML。

    输出只保留 p / h2 / h3 / li / blockquote / img 结构——足以让
    pandoc 排版长文，同时剥离公众号页面的脚本与样式。
    """
    KEEP = {"p", "h2", "h3", "li", "blockquote", "br"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root_id = None            # 要抽取的容器 id
        self.depth = 0                 # 容器内 div 嵌套深度
        self.in_root = False
        self.capture = 0               # >0 时输出到 out
        self.out = []
        self.title = ""
        self.in_title = False
        self.seen_root = False
        self.img_n = 0
        self.media_dir = None          # 由调用方设置（Path）
        self.base_url = ""
        self.img_fail = 0

    # -- 标题 --
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "meta" and a.get("property") == "og:title" and not self.title:
            self.title = a.get("content", "").strip()
        if not self.in_root and a.get("id") in ("js_content",):
            self.root_id, self.in_root, self.depth, self.seen_root = a["id"], True, 0, True
            return
        if not self.in_root and tag == "article":
            self.in_root, self.depth, self.seen_root = True, 0, True
            return
        if self.in_title or (tag == "title" and not self.title):
            self.in_title = True
            return
        if not self.in_root:
            return
        if tag == "div":
            self.depth += 1
        if tag == "img":
            self._emit_img(a)
        elif tag in self.KEEP:
            self.capture += 1
            self.out.append("<%s>" % tag)
        elif tag == "strong":
            self.out.append("<strong>"); self.capture += 1
        elif tag == "em":
            self.out.append("<em>"); self.capture += 1

    def handle_endtag(self, tag):
        if self.in_title:
            if tag == "title":
                self.in_title = False
            return
        if not self.in_root:
            return
        if tag == "div":
            self.depth -= 1
            if self.depth < 0:         # 容器关闭
                self.in_root = False
            return
        if tag in ("strong", "em") and self.capture:
            self.out.append("</%s>" % tag)
            self.capture -= 1
            return
        if tag in self.KEEP and self.capture:
            self.out.append("</%s>" % tag)
            self.capture -= 1

    def handle_data(self, data):
        if self.in_title:
            t = data.strip()
            if t and not self.title:
                self.title = t
        if self.in_root and data.strip():
            self.out.append(html_mod.escape(data))

    # -- 图片：data-src 懒加载 → 下载到本地 media/ --
    def _emit_img(self, a):
        src = a.get("data-src") or a.get("src") or ""
        if not src or "spacer" in src or "mmbiz_svg" in src:
            return
        url = abs_img(src, self.base_url)
        ext = ".jpg"
        m = re.search(r"wx_fmt=(\w+)", url)
        if m:
            ext = "." + m.group(1).lower()
        else:
            m2 = re.search(r"\.(\w{3,4})(?:[?#]|$)", url)
            if m2:
                ext = "." + m2.group(1).lower()
        self.img_n += 1
        local = self.media_dir / f"img_{self.img_n:03d}{ext}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=8) as r:
                data = r.read(8 * 1024 * 1024)
            if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
                raise ValueError("webp")   # typst 不支持 webp，跳过
            local.write_bytes(data)
            self.out.append('<img src="media/%s" alt="">' % local.name)
        except Exception:
            self.img_fail += 1

    def result(self):
        return "".join(self.out).strip()


def extract_article(html_text: str, url: str, work: Path):
    """返回 (title, html_fragment, media_dir|None)。fragment 内图片为相对路径。"""
    ex = ArticleExtractor()
    m = re.search(r'<title[^>]*>(.*?)</title>', html_text, re.S | re.I)
    ex.title = html_mod.unescape(m.group(1)).strip() if m else ""
    ex.base_url = url
    # 先探测是否公众号页面，决定是否需要 media 目录
    has_mmbiz = "mmbiz.qpic.cn" in html_text or 'id="js_content"' in html_text
    media = None
    if has_mmbiz:
        media = work / "media"
        media.mkdir(parents=True, exist_ok=True)
    ex.media_dir = media or work
    try:
        ex.feed(html_text)
    except Exception:
        pass
    frag = ex.result()
    title = (ex.title or "未命名文章").replace('"', "'")
    if frag:
        return title, frag, media
    # 兜底：整页剥标签为纯文本
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", html_text,
                  flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", "\n", text)
    text = html_mod.unescape(re.sub(r"\n{3,}", "\n\n", text))
    lines = [l.strip() for l in text.splitlines()]
    body = "\n\n".join(l for l in lines if l)
    return title, "<p>%s</p>" % html_mod.escape(body[:80000]), None


# ---- 主 Handler --------------------------------------------------------------
def md_from_text(text: str, title: str) -> str:
    if title and not re.match(r"^---\s*\n", text):
        safe = title.replace('"', '\\"')
        text = f'---\ntitle: "{safe}"\n---\n\n{text}'
    return text


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "p2q-relay/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"),
                                        fmt % args))

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        tok = self.headers.get("X-Relay-Token", "")
        if not tok:
            q = urllib.parse.parse_qs(
                urllib.parse.urlparse(self.path).query)
            tok = (q.get("token") or [""])[0]
        return tok == TOKEN

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/health":
            paired, addr = api_state()
            self._json({"ok": True,
                        "client_installed": Path(QUADERNO_APP).exists(),
                        "api_paired": paired,
                        "api_addr": addr})
        elif path == "/pair":
            q = urllib.parse.parse_qs(parsed.query)
            tok = (q.get("token") or [""])[0]
            body = PAIR_HTML.replace("__TOKEN__", html_mod.escape(tok)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/pair/status":
            paired, addr = api_state()
            self._json({"ok": True, "paired": paired, "addr": addr})
        else:
            self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/pair/discover", "/pair/start", "/pair/finish"):
            if not self._auth():
                self._json({"ok": False, "error": "token 无效"}, 401)
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                payload = json.loads(self.rfile.read(length) or b"{}")
            except Exception as e:
                self._json({"ok": False, "error": f"请求体解析失败: {e}"}, 400)
                return
            if path == "/pair/discover":
                self._json(_dp_pair("discover", timeout=120))
            elif path == "/pair/start":
                addr = str(payload.get("addr") or "").strip()
                if not addr:
                    self._json({"ok": False, "error": "缺少 addr"}, 400)
                    return
                self._json(_dp_pair(
                    "start", "--addr", addr,
                    "--port", str(int(payload.get("port") or 8443)),
                    "--reg-port", str(int(payload.get("reg_port") or 8443)),
                    timeout=120))
            else:
                pin = str(payload.get("pin") or "").strip()
                if not pin:
                    self._json({"ok": False, "error": "缺少 pin"}, 400)
                    return
                self._json(_dp_pair("finish", "--pin", pin, timeout=120))
            return

        if path != "/deliver":
            self.send_error(404); return
        if not self._auth():
            self._json({"ok": False, "error": "token 无效"}, 401); return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception as e:
            self._json({"ok": False, "error": f"请求体解析失败: {e}"}, 400); return

        ptype = payload.get("type", "text")
        title = str(payload.get("title", "")).strip()
        plain = bool(payload.get("plain", True))
        t0 = time.time()

        try:
            if ptype == "text":
                content = str(payload.get("content", ""))
                if not content.strip():
                    self._json({"ok": False, "error": "content 为空"}, 400); return
                title = title or _first_h1(content) or "快投文稿"
                work = Path(tempfile.mkdtemp(prefix="p2q_", dir=str(WORK)))
                src = work / "input.md"
                src.write_text(md_from_text(content, title), encoding="utf-8")
            elif ptype == "url":
                url = str(payload.get("url", "")).strip()
                if not re.match(r"^https?://", url):
                    self._json({"ok": False, "error": "url 非法"}, 400); return
                html_text = fetch_url(url)
                work = Path(tempfile.mkdtemp(prefix="p2q_", dir=str(WORK)))
                title, frag, media = extract_article(html_text, url, work)
                if title == "未命名文章" and payload.get("title"):
                    title = str(payload["title"]).strip()
                src = work / "article.html"
                src.write_text(
                    '<!DOCTYPE html><html><head><meta charset="utf-8">'
                    f"<title>{html_mod.escape(title)}</title></head>"
                    f"<body><h1>{html_mod.escape(title)}</h1>{frag}</body></html>",
                    encoding="utf-8")
            else:
                self._json({"ok": False, "error": f"未知 type: {ptype}"}, 400); return
        except Exception as e:
            self._json({"ok": False, "error": f"抓取/抽取失败: {e}"}, 502); return

        cfg = read_config()
        slug = hashlib.md5(title.encode()).hexdigest()[:8]
        safe_title = re.sub(r'[/\\:*?"<>|]', "_", title)[:60] or "doc"
        out = work / f"{safe_title}_{slug}.pdf"
        try:
            r = render(src, out, cfg, plain=plain)
        except subprocess.TimeoutExpired:
            self._json({"ok": False, "error": "渲染超时（>600s）"}, 500); return
        if r.returncode != 0 or not out.exists():
            err = (r.stderr or r.stdout or "unknown")[-500:]
            self._json({"ok": False, "error": "渲染失败: " + err}, 500); return

        pages = pdf_pages(out)
        with DELIVER_LOCK:
            result = deliver_via_api(out, title)
            if result is None:                      # API 路径未启用/不可用 → 后备官方客户端
                result = deliver_pdf(out, title)
            status, detail, via = result

        self._json({
            "ok": True, "status": status, "detail": detail,
            "title": title, "pages": pages,
            "elapsed_s": round(time.time() - t0, 1),
            "device": "QUADERNO A5",
            "via": via,
        })


def _first_h1(text: str):
    m = re.search(r"^#\s+(.+)$", text, re.M)
    return m.group(1).strip() if m else ""


TOKEN = load_token()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()

    httpd = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"p2q-relay listening on {args.bind}:{args.port}", flush=True)
    print(f"token file: {TOKEN_FILE}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
