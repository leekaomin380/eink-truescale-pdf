#!/usr/bin/env python3
"""
gui/server.py · print-to-quaderno 本地图形界面（后端）

设计原则：
  本服务只是一层壳。所有转换逻辑一律调用 book.sh，不在此重复实现 ——
  否则 CLI 与 GUI 会各自演化，页面几何这类核心参数早晚分叉。

仅使用 Python 标准库，无需 pip 安装任何东西。
预览渲染需要 poppler 的 pdftoppm（brew install poppler），缺失时会明确提示。
"""

import base64
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import tempfile
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
BOOK_SH = REPO / "book.sh"
CONFIG_SH = REPO / "config.sh"
WORK = Path(tempfile.gettempdir()) / "p2q_gui"
WORK.mkdir(exist_ok=True)

ENV = {
    **os.environ,
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "PATH": "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", ""),
}


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, env=ENV, **kw)


def read_config():
    """从 config.sh 解析默认值 —— 单一事实来源，GUI 不另存一份。"""
    txt = CONFIG_SH.read_text(encoding="utf-8")
    def grab(key, default=""):
        m = re.search(rf'^{key}="([^"]*)"', txt, re.M)
        return m.group(1) if m else default
    fonts = re.search(r'^FONTS=\((.*?)\)', txt, re.M)
    font_list = re.findall(r'"([^"]+)"', fonts.group(1)) if fonts else []
    return {
        "page_w": grab("PAGE_W", "157.1mm"),
        "page_h": grab("PAGE_H", "209.5mm"),
        "margin": grab("PAGE_MARGIN", "10mm"),
        "size": grab("BODY_SIZE", "10pt"),
        "leading": grab("LEADING", "0.85em"),
        "lang": grab("DOC_LANG", "zh"),
        "fonts": font_list,
    }


def list_fonts():
    """列出系统可用字体，挑出适合正文的常见项放在前面。"""
    r = sh(["typst", "fonts"])
    if r.returncode != 0:
        return {"cjk": [], "latin": [], "all": []}
    all_fonts = sorted(set(l.strip() for l in r.stdout.splitlines() if l.strip()))
    cjk_pref = ["PingFang SC", "Songti SC", "Heiti SC", "STSong", "Hiragino Sans GB",
                "Noto Serif CJK SC", "Source Han Sans SC", "Source Han Serif SC"]
    latin_pref = ["Charter", "Iowan Old Style", "Georgia", "Palatino", "Times New Roman",
                  "Helvetica Neue", "Arial", "Avenir Next"]
    cjk = [f for f in cjk_pref if f in all_fonts]
    latin = [f for f in latin_pref if f in all_fonts]
    return {"cjk": cjk, "latin": latin, "all": all_fonts}


def pdf_pages(pdf: Path):
    r = sh(["pdfinfo", str(pdf)])
    m = re.search(r"Pages:\s+(\d+)", r.stdout)
    return int(m.group(1)) if m else 0


def pdf_page_sizes(pdf: Path, n: int):
    """返回所有不同的页面尺寸 —— 用于守护不变量 I1（尺寸必须统一）。"""
    r = sh(["pdfinfo", "-f", "1", "-l", str(n), str(pdf)])
    sizes = set(re.findall(r"Page\s+\d+ size:\s+([\d.]+ x [\d.]+)", r.stdout))
    return sorted(sizes)


def mm(v):
    return float(str(v).replace("mm", ""))


def pt(v):
    return float(str(v).replace("pt", ""))


def metrics(cfg, pages=None, sizes=None):
    """数字读数 —— 与预览缩放无关，不会因显示比例误导判断。"""
    measure = mm(cfg["page_w"]) - 2 * mm(cfg["margin"])
    size_mm = pt(cfg["size"]) * 25.4 / 72
    cjk_per_line = measure / size_mm
    latin_per_line = measure / (size_mm * 0.5)      # 拉丁字符平均约半宽
    out = {
        "measure_mm": round(measure, 1),
        "cjk_per_line": round(cjk_per_line),
        "latin_per_line": round(latin_per_line),
        "page_w": cfg["page_w"], "page_h": cfg["page_h"],
        "size": cfg["size"],
    }
    if pages is not None:
        out["pages"] = pages
    if sizes is not None:
        out["page_sizes"] = sizes
        out["size_uniform"] = (len(sizes) == 1)
    # 行长健康度判断（依据见 docs/typography-for-eink.md）
    out["cjk_verdict"] = ("偏密" if cjk_per_line > 45 else
                          "偏长" if cjk_per_line > 40 else
                          "合适" if cjk_per_line >= 28 else "偏短")
    out["latin_verdict"] = ("偏长" if latin_per_line > 75 else
                            "合适" if latin_per_line >= 45 else "偏短")
    return out


def convert(src: Path, cfg, out: Path):
    cmd = [str(BOOK_SH), str(src), "-o", str(out),
           "--size", cfg["size"], "--margin", cfg["margin"],
           "--leading", cfg["leading"], "--lang", cfg["lang"],
           "--font", ",".join(cfg["fonts"])]
    return sh(cmd)


def render_page(pdf: Path, page: int, dpi: int = 110):
    if not shutil.which("pdftoppm"):
        return None, "预览需要 poppler：brew install poppler"
    prefix = WORK / f"prev_{page}"
    for old in WORK.glob("prev_*.png"):
        old.unlink(missing_ok=True)
    r = sh(["pdftoppm", "-f", str(page), "-l", str(page), "-r", str(dpi),
            "-png", str(pdf), str(prefix)])
    if r.returncode != 0:
        return None, r.stderr[:200]
    files = sorted(WORK.glob(f"prev_{page}-*.png"))
    if not files:
        return None, "未生成预览图"
    return files[0], None


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            html = (ROOT / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
        elif path == "/api/init":
            self._json({"config": read_config(), "fonts": list_fonts(),
                        "has_poppler": bool(shutil.which("pdftoppm"))})
        elif path.startswith("/preview.png"):
            f = WORK / "current_preview.png"
            if not f.exists():
                self.send_error(404); return
            data = f.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")

        if path == "/api/upload":
            name = Path(payload["name"]).name
            dst = WORK / name
            dst.write_bytes(base64.b64decode(payload["data"]))
            self._json({"ok": True, "path": str(dst), "name": name})

        elif path == "/api/convert":
            src = Path(payload["path"])
            cfg = payload["config"]
            out = WORK / (src.stem + ".pdf")
            r = convert(src, cfg, out)
            if r.returncode != 0 or not out.exists():
                self._json({"ok": False, "error": (r.stderr or r.stdout)[-800:]})
                return
            n = pdf_pages(out)
            sizes = pdf_page_sizes(out, n)
            self._json({"ok": True, "pdf": str(out),
                        "metrics": metrics(cfg, pages=n, sizes=sizes)})

        elif path == "/api/preview":
            pdf = Path(payload["pdf"])
            page = int(payload.get("page", 1))
            img, err = render_page(pdf, page)
            if err:
                self._json({"ok": False, "error": err}); return
            shutil.copy(img, WORK / "current_preview.png")
            self._json({"ok": True, "url": "/preview.png?p=" + str(page)})

        elif path == "/api/deliver":
            pdf = Path(payload["pdf"])
            app = "/Applications/QUADERNO PC App.app"
            if not Path(app).exists():
                self._json({"ok": False, "error": "未找到 QUADERNO 客户端"}); return
            # 客户端上传后会 unlink 源文件 —— 必须投递副本，保护产物（不变量 I2）
            copy = WORK / ("deliver_" + pdf.name)
            shutil.copy(pdf, copy)
            sh(["open", "-gj", "-na", app, "--args", "--print", str(copy)])
            self._json({"ok": True})

        elif path == "/api/save":
            pdf = Path(payload["pdf"])
            dest = Path(payload["dest"]).expanduser()
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(pdf, dest)
                self._json({"ok": True, "saved": str(dest)})
            except Exception as e:
                self._json({"ok": False, "error": str(e)})
        else:
            self.send_error(404)


def main(port=8777):
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
        print(f"print-to-quaderno GUI  →  http://127.0.0.1:{port}")
        print("按 Ctrl-C 停止")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")


if __name__ == "__main__":
    import sys
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 8777)
