#!/usr/bin/env python3
"""Generate the static, crawlable product pages for TrueScale for QUADERNO.

The previous single page injected Chinese and Japanese copy with JavaScript at
runtime: the HTML a search engine received contained English only. Each language
now owns its own URL, its own <html lang>, title, description, canonical,
hreflang set and JSON-LD. The visual rules live in assets/site.css; all four locales share the same layout.

    python3 site/build.py            # regenerate index.html, zh/, zh-hant/, ja/, sitemap, robots
    python3 site/build.py --check    # exit 1 if the committed output is stale

The generated HTML is committed, so GitHub Pages serves plain static files with
no build step. Edit the copy in CONTENT (or the shared constants) and re-run.
"""
from __future__ import annotations

import argparse
import html
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

SITE = Path(__file__).resolve().parent
SITE_URL = "https://leekaomin380.github.io/eink-truescale-pdf/"
REPO = "https://github.com/leekaomin380/eink-truescale-pdf"
RELEASES = REPO + "/releases/latest"
CHANGELOG = REPO + "/blob/master/CHANGELOG.md"
LATEST = "1.3.0"
APP_RELEASE_DATE = "2026-11-07"
LASTMOD = "2026-11-14"
CSS_VERSION = hashlib.sha256((SITE / "assets/site.css").read_bytes()).hexdigest()[:12]

LANGS = {
    "en": {"dir": "", "lang": "en", "hreflang": "en", "locale": "en_US", "label": "English"},
    "zh": {"dir": "zh/", "lang": "zh-Hans", "hreflang": "zh-Hans", "locale": "zh_CN", "label": "简体中文"},
    "zh-hant": {"dir": "zh-hant/", "lang": "zh-Hant", "hreflang": "zh-Hant", "locale": "zh_TW", "label": "正體中文"},
    "ja": {"dir": "ja/", "lang": "ja", "hreflang": "ja", "locale": "ja_JP", "label": "日本語"},
}

CONTENT = {
    "en": {
        "meta": {
            "title": "TrueScale for QUADERNO — 1:1 PDF, EPUB & Markdown for QUADERNO A5 (Mac)",
            "description": "Free open-source Mac app for FUJITSU QUADERNO: copy text and press ⌃1, or right-click a PDF/EPUB in Finder. True 1:1 page size, direct USB/Wi-Fi delivery, SHA-256 verified.",
            "keywords": "QUADERNO, FUJITSU QUADERNO A5, FMVDP51, QUADERNO PDF blurry, QUADERNO true size PDF, send PDF to QUADERNO from Mac, QUADERNO EPUB to PDF, QUADERNO e-ink, e-paper typography, Markdown to PDF, macOS",
            "og_desc": "Typeset for the page you hold. Copy text, press ⌃1, and it opens on your QUADERNO.",
            "og_alt": "TrueScale for QUADERNO — a QUADERNO A5 page typeset at true physical size",
            "nav_label": "Sections",
            "lang_label": "Language",
            "jsonld_summary": "A free, open-source macOS app that typesets text, Markdown, PDFs, EPUB and WeChat articles at the true physical size of a FUJITSU QUADERNO screen and delivers them directly over USB or Wi-Fi.",
        },
        "nav": {"features": "Features", "changelog": "Changelog", "faq": "FAQ"},
        "hero": {
            "title": "Typeset for the page you hold.",
            "lead": "Copy text on your Mac, press a key, and it opens on your FUJITSU QUADERNO — laid out at the screen's true physical size, so it reads as sharply as print.",
            "copy": "Copy", "open": "Open on QUADERNO",
            "download": "Download for Mac", "source": "Source on GitHub",
            "version": "Version", "note": "Free and open source (MIT). Apple Silicon, macOS 14 or later.",
        },
        "why": {
            "title": "Why PDFs look blurry on e-paper",
            "intro": "An A4 page shrunk onto a 10.3-inch screen loses sharpness in the resampling — not for lack of pixels. TrueScale measures the screen first, then sets the page to exactly that size.",
            "measured": "Measured, not assumed",
            "measuredText": "Derived from 1404 × 1872 pixels on a 10.3-inch diagonal (227.18 dpi, within 0.08% of the published 227 dpi), then checked with a ruler: a 100 mm line on the screen measures 100 mm.",
            "scale": "No scaling on the device",
            "scaleText": "Because the page is the screen, the device shows it untouched. 10.5 pt on the page is a real 10.5 pt under your pen — the same size it would be in a printed book.",
        },
        "ways": {
            "title": "Four ways in, none of them a dialog",
            "intro": "Everything is saved to Received on the device and opens on screen. Nothing on the device is ever overwritten.",
            "hotkey": "⌃1 from the clipboard",
            "hotkeyText": "Copy any text or Markdown and press ⌃1. Named, typeset and delivered in about two seconds.",
            "finder": "Right-click in Finder",
            "finderText": "“Send to QUADERNO” on any PDF, EPUB, Markdown or text file. Several at once, with no window.",
            "books": "E-books and web articles",
            "booksText": "EPUB, MOBI, FB2, HTML and WeChat articles, with a table of contents and bookmarks.",
            "shot": "Screenshots, back to the Mac",
            "shotText": "⌃2 or one click saves the device screen — handwriting included — as PNG, JPEG or a true-size PDF into a folder you chose once.",
        },
        "trust": {
            "title": "Built to be trusted with your notes",
            "items": [
                ("Direct over USB or Wi-Fi", "Talks to the device itself. QUADERNO PC App does not need to be open."),
                ("Read back and verified", "Every upload is downloaded again and checked by SHA-256 before it counts as delivered."),
                ("Pinned device identity", "The device's public key is pinned at pairing; a different key is refused, never trusted."),
                ("Device files", "Browse, search, download with handwriting, upload, move and delete — deleting always asks first."),
                ("Recent deliveries", "Every send, from every entry point. Failed ones keep their PDF for one-click retry."),
                ("中文 · English · 日本語", "The app and its notifications in three languages, switchable in Settings."),
            ],
        },
        "caps": {
            "title": "Features, in detail",
            "intro": "Every entry point shares one rendering and delivery pipeline. This is the full surface, including the newer handling of tables and rich text.",
            "groups": [
                ("True-size typesetting", "The page is the screen, so 10.5 pt on the page is a real 10.5 pt under the pen.", [
                    "Measured QUADERNO A5 display area: 156.97 × 209.30 mm at 227.18 ppi",
                    "Adjustable font, size, margins and leading, with a page preview",
                    "pandoc → Typst → PDF; both engines ship inside the app",
                    "A4 (FMVDP41) works after changing two values",
                ]),
                ("What you can send", "One pipeline for short notes, whole books and web articles.", [
                    "Clipboard plain text, Markdown, rich HTML tables and TSV",
                    "PDF, EPUB, MOBI, FB2, HTML and TXT via Finder right-click",
                    "WeChat articles (微信公众号) by pasting a link — extracted locally, no account",
                    "Type or paste directly into the app",
                ]),
                ("Tables and rich text", "Content copied from an AI reply or a web page keeps its structure.", [
                    "HTML tables, TSV blocks and GFM pipe tables are normalised before rendering",
                    "Column widths follow content length; explicit alignment is preserved",
                    "Long tables paginate with a repeating header instead of being shrunk",
                    "Over-wide tables degrade to a readable list; plain text stays byte-for-byte unchanged",
                ]),
                ("Direct delivery, verified", "The device is the endpoint; the official client is optional.", [
                    "HTTPS over USB or local network, with the device public key pinned at pairing",
                    "Files land in Document/Received/ and are opened on screen",
                    "Read back and compared by SHA-256, then confirmed in the directory listing",
                    "One transfer at a time; failures keep the PDF for retry and clean up after themselves",
                    "Falls back to QUADERNO PC App only before an upload starts",
                ]),
                ("Files and screenshots", "Work with what is already on the device.", [
                    "Browse, search, sort, download with handwriting, upload, move and delete — delete always asks",
                    "⌃2 / ⌘⇧S saves the screen as PNG, JPEG or a true-size PDF",
                    "Screenshots are named after the open document and page",
                    "Recent Deliveries lists every entry point, with Retry and Reveal in Finder",
                ]),
                ("App and workflow", "Native on macOS, and still scriptable.", [
                    "Menu-bar resident with built-in ⌃1 / ⌃2 hotkeys; no Shortcuts setup",
                    "简体中文 / English / 日本語 interface and notifications",
                    "Self-contained bundle: no Homebrew, no Terminal required",
                    "Command-line book.sh / deliver.sh and a source build use the same pipeline",
                ]),
            ],
        },
        "start": {
            "title": "Getting started",
            "steps": [
                "Download the app and drag it into Applications.",
                "Connect your QUADERNO by USB. The setup guide opens by itself.",
                "Import Pairing, then Check. Right-click sending, ⌃1 and ⌃2 work immediately — no setup in the Shortcuts app.",
            ],
            "req": [
                "Apple Silicon Mac, macOS 14 or later.",
                "FUJITSU QUADERNO A5 (FMVDP51), tested. A4 (FMVDP41) works, but its page size is derived rather than measured yet.",
                "A pairing created once by QUADERNO PC App on the same Mac. Pairing a new device by PIN is not implemented yet.",
            ],
        },
        "releases": {
            "title": "Version history",
            "intro": "Released versions, newest first, each linked to its GitHub Release.",
            "full": "Full changelog on GitHub",
            "entries": [
                {"tag": "1.3.0", "date": "2026-11-07", "title": "Clipboard fidelity, table layout and delivery hardening", "link": REPO + "/releases/tag/v1.3.0", "items": [
                    "EPUB and PDF names containing “·” no longer make the device report “the file has been deleted”; non-UTF-8 device responses no longer abort the transaction.",
                    "⌃1 reads rich HTML from the clipboard: HTML tables, TSV and GFM pipe tables are normalised, while plain text and formulas pass through unchanged.",
                    "Complex tables get content-proportional columns, paginate with repeating headers and degrade to a list when over-wide. Authentication now overlaps typesetting to cut latency without shortening the verification chain.",
                    "Concurrent deliveries now queue, USB link faults are detected separately, and uploads gain bounded timeouts, empty-PDF rejection and idempotency checks.",
                ]},
                {"tag": "1.2.2", "date": "2026-11-02", "title": "Hotkeys, quiet Finder delivery and EPUB", "link": REPO + "/releases/tag/v1.2.2", "items": [
                    "Built-in ⌃1 / ⌃2 hotkeys; Finder right-click no longer shows the app.",
                    "Finder right-click delivery for EPUB, typeset as a book.",
                    "Screenshots named after the open document and page; the app stays in the menu bar.",
                ]},
                {"tag": "1.2.1", "date": "2026-11-01", "title": "A quieter icon", "link": REPO + "/releases/tag/v1.2.1", "items": [
                    "Grayscale paper icon with an italic lowercase q; the site icon and favicon follow the same design.",
                ]},
                {"tag": "1.2.0", "date": "2026-11-01", "title": "Direct delivery and the TrueScale rename", "link": REPO + "/releases/tag/v1.2.0", "items": [
                    "Renamed from Quaderno Converter; one-time settings migration.",
                    "Direct USB / LAN delivery with a pinned public key, SHA-256 read-back and a bounded fallback to the official client.",
                    "Finder right-click sending, 简体中文 / English / 日本語 UI, first-run guide, Device Files and screenshot export.",
                ]},
            ],
        },
        "faq": {
            "title": "Frequently asked questions",
            "intro": "Short answers about sizing, compatibility, supported sources and delivery safety.",
            "items": [
                ("Why do PDFs look blurry on a QUADERNO, and how do I fix it?",
                 "Usually an A4 or Letter page is being shrunk onto the 10.3-inch screen; resampling softens the strokes. TrueScale builds the page at the QUADERNO A5's measured display area (156.97 × 209.30 mm), so the device never rescales it and 227 ppi is shown as-is. The calibration page verifies 1:1 on any e-ink device."),
                ("Can I send files from a Mac to QUADERNO without opening QUADERNO PC App?",
                 "Yes. TrueScale talks to the device over HTTPS on USB or the local network, reusing a pairing imported once from the official app. After that the official client does not need to run. If the direct link is unavailable before an upload starts and the official app happens to be running, delivery falls back to its print queue."),
                ("What sources are supported — EPUB, WeChat articles, tables copied from an AI reply?",
                 "Plain text, Markdown and rich HTML from the clipboard; PDF, EPUB, MOBI, FB2, HTML and TXT files from Finder; WeChat Official Account (微信公众号) articles by link; and text typed into the app. Tables copied from an AI reply are normalised from HTML, TSV or GFM pipe form, with column widths and alignment preserved. WeChat extraction runs locally on the Mac."),
                ("What are the QUADERNO A5 (FMVDP51) display dimensions and resolution?",
                 "10.3 inches diagonal, 1404 × 1872 pixels, 227.18 ppi, with a display area of 156.97 × 209.30 mm. A 100 mm line drawn on the screen measures 100 mm with a ruler. The downloadable calibration page lets you check the same 1:1 behaviour on any reader."),
                ("Does it work with QUADERNO A4 (FMVDP41), Intel Macs or Windows?",
                 "A4 works, but its page size is still derived rather than measured; change two values before use. The prebuilt bundle is Apple Silicon and macOS 14 or later only. An Intel Mac can be built from source for its own architecture. Windows is not supported."),
                ("Will a delivery overwrite or delete files on my QUADERNO?",
                 "No. Files are only written to Document/Received/ and opened on screen. Moving and deleting are explicit actions in Device Files and always ask for confirmation. Every upload is read back from the device and compared by SHA-256 before it counts as delivered."),
                ("Is it free, open source, and affiliated with Fujitsu?",
                 "It is free and open source under the MIT licence. TrueScale for QUADERNO is an independent project, not affiliated with, endorsed or sponsored by Fujitsu. FUJITSU and QUADERNO are trademarks of their respective owners."),
            ],
        },
        "foot": {
            "independent": "TrueScale for QUADERNO is an independent open-source project. It is not affiliated with, endorsed or sponsored by Fujitsu. FUJITSU and QUADERNO are trademarks of their respective owners.",
            "license": "MIT License. Bundles pandoc, Typst and other components under their own licenses — listed in the app's About page.",
            "issues": "Report an issue", "contact": "Contact: ",
        },
    },
    "zh": {
        "meta": {
            "title": "TrueScale for QUADERNO：QUADERNO A5 1:1 实际尺寸 PDF／EPUB 投递工具（Mac 开源）",
            "description": "免费开源的 macOS 工具：复制文字按 ⌃1，或在 Finder 右键 PDF／EPUB 直接投递到 FUJITSU QUADERNO。按屏幕真实物理尺寸 1:1 排版，USB／局域网直连、SHA-256 回读校验，无需官方客户端。",
            "keywords": "QUADERNO, 富士通 QUADERNO A5, FMVDP51, QUADERNO PDF 模糊, QUADERNO 传文件 Mac, QUADERNO 1:1 排版, QUADERNO EPUB 转 PDF, 电子纸 排版, 微信公众号文章 QUADERNO, 电子书 转换, 快捷键 ⌃1, macOS",
            "og_desc": "为你手中的这一页排版。复制文字，按 ⌃1，它就出现在 QUADERNO 上。",
            "og_alt": "TrueScale for QUADERNO —— 按真实物理尺寸排版的 QUADERNO A5 页面",
            "nav_label": "页面导航",
            "lang_label": "语言",
            "jsonld_summary": "免费开源的 macOS 应用：把文字、Markdown、PDF、EPUB 与微信公众号文章按 FUJITSU QUADERNO 屏幕的真实物理尺寸排版，并通过 USB 或局域网直接投递。",
        },
        "nav": {"features": "功能说明", "changelog": "版本日志", "faq": "常见问题"},
        "hero": {
            "title": "为你手中的这一页排版。",
            "lead": "在 Mac 上复制文字，按一个键，它就出现在 FUJITSU QUADERNO 上——按屏幕的真实物理尺寸排版，读起来像印刷品一样清晰。",
            "copy": "复制", "open": "在 QUADERNO 上打开",
            "download": "下载 Mac 版", "source": "GitHub 源代码",
            "version": "版本", "note": "免费、开源（MIT）。需要 Apple Silicon 芯片、macOS 14 或更新版本。",
        },
        "why": {
            "title": "为什么 PDF 在电子纸上看起来模糊",
            "intro": "A4 尺寸的页面被缩小到 10.3 英寸的屏幕上，笔画在重采样中变虚——问题不在像素不够。TrueScale 先量清楚屏幕，再把页面做成恰好这么大。",
            "measured": "实测，而不是假设",
            "measuredText": "由 1404 × 1872 像素和 10.3 英寸对角线推算（227.18 dpi，与公布的 227 dpi 相差 0.08%），再用直尺验证：屏幕上一条 100 mm 的线，量出来正好 100 mm。",
            "scale": "设备上不再缩放",
            "scaleText": "页面就是屏幕，设备原样显示。页面上的 10.5 磅，就是笔尖下真实的 10.5 磅，和印刷书里一样大。",
        },
        "ways": {
            "title": "四个入口，没有一个需要弹窗",
            "intro": "投递的文件都保存到设备的 Received，并在屏幕上打开。设备上的任何文件都不会被覆盖。",
            "hotkey": "剪贴板 + ⌃1",
            "hotkeyText": "复制任意文字或 Markdown，按 ⌃1。自动命名、排版、投递，约两秒。",
            "finder": "Finder 右键",
            "finderText": "对 PDF、EPUB、Markdown 或文本文件选择「投递到 QUADERNO」，可以多选，不弹出窗口。",
            "books": "电子书与网页文章",
            "booksText": "EPUB、MOBI、FB2、HTML 和微信公众号文章，带目录与书签。",
            "shot": "截屏，传回 Mac",
            "shotText": "按 ⌃2 或点一下，保存设备屏幕（包括手写笔迹），格式可选 PNG、JPEG 或实际尺寸的 PDF，存进预先选好的文件夹。",
        },
        "trust": {
            "title": "可以放心交给它的笔记",
            "items": [
                ("USB 或 Wi-Fi 直连", "直接和设备通信，不需要打开 QUADERNO PC App。"),
                ("回读校验", "每次上传后都会读回文件、核对 SHA-256，确认无误才算送达。"),
                ("固定设备身份", "配对时固定设备公钥；换了公钥的设备会被拒绝，不会被信任。"),
                ("设备文件", "浏览、搜索、连同手写批注下载、上传、移动、删除——删除前一定会确认。"),
                ("最近投递", "所有入口的每一次投递。失败的保留 PDF，一键重试。"),
                ("中文 · English · 日本語", "App 与通知都有三种语言，可在设置中切换。"),
            ],
        },
        "caps": {
            "title": "功能说明",
            "intro": "所有入口共用同一条排版与投递链路。下面是完整的功能清单，包含新增的表格与富文本保真处理。",
            "groups": [
                ("按真实尺寸排版", "页面就是屏幕，页面上的 10.5 磅，就是笔尖下真实的 10.5 磅。", [
                    "QUADERNO A5 显示区实测值：156.97 × 209.30 mm、227.18 ppi",
                    "字体、字号、页边距与行距可调，并可逐页预览",
                    "pandoc → Typst → PDF；两个排版引擎都打包在 App 内",
                    "A4（FMVDP41）修改两个参数后即可使用",
                ]),
                ("可以发送什么", "短笔记、整本书、网页文章，走同一条链路。", [
                    "剪贴板中的纯文本、Markdown、富文本 HTML 表格与 TSV",
                    "Finder 右键投递 PDF、EPUB、MOBI、FB2、HTML、TXT",
                    "粘贴微信公众号文章链接即可转换，提取全程在本机完成，无需账号",
                    "也可以直接在 App 里输入或粘贴文字",
                ]),
                ("表格与富文本", "从 AI 回复或网页复制的内容，结构不会散掉。", [
                    "渲染前归一化 HTML 表格、TSV 区块与 GFM 管道表格",
                    "列宽按单元格内容长度分配，原有对齐方式保持不变",
                    "长表格分页显示并重复表头，而不是整体缩小",
                    "超宽表格降级为易读的列表；纯文本逐字不变",
                ]),
                ("直连投递与校验", "终点是设备本身，官方客户端只是可选项。", [
                    "USB 或局域网 HTTPS 直连，配对时固定设备公钥",
                    "文件写入 Document/Received/ 并在屏幕上打开",
                    "回读文件核对 SHA-256，再确认目录条目后才算送达",
                    "同一时间只进行一次传输；失败保留 PDF 供重试，并自动清理残留",
                    "仅当上传尚未开始且官方 App 正在运行时，才降级到它的打印队列",
                ]),
                ("文件管理与截屏", "设备里已有的内容同样可以操作。", [
                    "浏览、搜索、排序、连同手写批注下载、上传、移动、删除——删除前一定确认",
                    "⌃2 / ⌘⇧S 把屏幕保存为 PNG、JPEG 或实际尺寸的 PDF",
                    "截屏按当前文档与页码命名",
                    "「最近投递」汇总所有入口，可重试、在 Finder 中显示",
                ]),
                ("应用形态与工作流", "原生 macOS 应用，同时保留命令行入口。", [
                    "菜单栏常驻，内置 ⌃1 / ⌃2 快捷键，无需在「快捷指令」里设置",
                    "简体中文 / English / 日本語 界面与通知",
                    "自包含安装包：不需要 Homebrew，也不需要终端",
                    "命令行 book.sh / deliver.sh 与源码构建复用同一条链路",
                ]),
            ],
        },
        "start": {
            "title": "开始使用",
            "steps": [
                "下载 App，拖进「应用程序」。",
                "用 USB 连接 QUADERNO，设置向导会自动打开。",
                "导入配对，然后自检。Finder 右键投递、⌃1 和 ⌃2 立即可用，无需在「快捷指令」里设置。",
            ],
            "req": [
                "Apple Silicon 芯片的 Mac，macOS 14 或更新版本。",
                "FUJITSU QUADERNO A5（FMVDP51）已实测。A4（FMVDP41）可用，但页面尺寸目前是推算值，尚未实测。",
                "需要这台 Mac 上已有 QUADERNO PC App 建立过一次的配对。用 PIN 全新配对尚未实现。",
            ],
        },
        "releases": {
            "title": "版本日志",
            "intro": "已发布的版本，按时间倒序排列，附对应 GitHub Release 链接。",
            "full": "在 GitHub 查看完整变更日志",
            "entries": [
                {"tag": "1.3.0", "date": "2026-11-07", "title": "剪贴板保真、表格版式与投递加固", "link": REPO + "/releases/tag/v1.3.0", "items": [
                    "修复文件名含「·」时设备误报「文件已被删除」；设备响应不再因非严格 UTF-8 解码而中断。",
                    "⌃1 读取剪贴板富文本：HTML 表格、TSV 与 GFM 表格归一化，纯文本与公式原样保留。",
                    "复杂表格按内容分配列宽、长表分页重复表头、超宽表降级为列表；设备认证与排版并行以降低延迟，校验链不缩减。",
                    "并发投递改为队列串行，USB 链路故障单独识别，上传增加超时上界、空 PDF 拦截与幂等跳过。",
                ]},
                {"tag": "1.2.2", "date": "2026-11-02", "title": "原生快捷键、静默右键投递与 EPUB", "link": REPO + "/releases/tag/v1.2.2", "items": [
                    "内置 ⌃1 / ⌃2 快捷键；Finder 右键不再弹出 App 窗口。",
                    "Finder 右键支持 EPUB，按书籍版式排版。",
                    "截屏按当前文档与页码命名；App 关闭窗口后仍常驻菜单栏。",
                ]},
                {"tag": "1.2.1", "date": "2026-11-01", "title": "更克制的图标", "link": REPO + "/releases/tag/v1.2.1", "items": [
                    "灰度纸张图标、左上角斜体小写 q；站点图标与 favicon 同步。",
                ]},
                {"tag": "1.2.0", "date": "2026-11-01", "title": "直连投递与 TrueScale 更名", "link": REPO + "/releases/tag/v1.2.0", "items": [
                    "由 Quaderno Converter 更名，首次启动自动迁移设置。",
                    "USB / 局域网直连，固定公钥、SHA-256 回读、上传前有界降级到官方客户端。",
                    "Finder 右键投递、简体中文 / English / 日本語 界面、首次设置向导、设备文件与截屏导出。",
                ]},
            ],
        },
        "faq": {
            "title": "常见问题",
            "intro": "关于尺寸、兼容性、支持的内容来源与投递安全的简要回答。",
            "items": [
                ("为什么 QUADERNO 上的 PDF 看起来模糊？怎么解决？",
                 "多数情况是 A4 / Letter 页面被缩小到 10.3 英寸屏幕，重采样让笔画变虚。TrueScale 按 QUADERNO A5 实测显示区（156.97 × 209.30 mm）生成页面，设备无需缩放，227 ppi 原样显示。校准页可在任意电子纸设备上验证 1:1。"),
                ("不打开 QUADERNO PC App，能从 Mac 直接传文件到 QUADERNO 吗？",
                 "可以。TrueScale 通过 USB 或局域网的 HTTPS 直连设备，配对信息从官方 App 一次性导入，之后官方客户端无需运行。若上传开始前直连不可用、且官方 App 正在运行，会自动降级到它的打印队列。"),
                ("支持哪些来源？EPUB、微信公众号文章、AI 回复里的表格都能发吗？",
                 "剪贴板纯文本、Markdown 与富文本 HTML；Finder 中的 PDF、EPUB、MOBI、FB2、HTML、TXT；粘贴微信公众号文章链接；以及 App 内直接输入。AI 回复中的表格会从 HTML、TSV 或 GFM 管道表格归一化，保留列宽与对齐。微信公众号提取全程在本机完成。"),
                ("QUADERNO A5（FMVDP51）的显示区尺寸和分辨率是多少？",
                 "10.3 英寸对角线、1404 × 1872 像素、227.18 ppi，显示区 156.97 × 209.30 mm。用直尺量屏幕上 100 mm 的线，结果正好 100 mm。可下载的校准页让你在任何阅读器上验证同样的 1:1 行为。"),
                ("A4（FMVDP41）、Intel Mac 或 Windows 能用吗？",
                 "A4 可用，但页面尺寸仍是推导值、尚未实测，使用前需改两个参数。预编译包仅支持 Apple Silicon 与 macOS 14 或更新版本；Intel Mac 可从源码按本机架构构建。不支持 Windows。"),
                ("投递会覆盖或删除 QUADERNO 上的文件吗？",
                 "不会。文件只写入 Document/Received/ 并在屏幕上打开。移动与删除只在「设备文件」里由你明确操作且二次确认。每次上传都会从设备回读并核对 SHA-256，通过后才算送达。"),
                ("是免费的吗？和富士通官方有关系吗？",
                 "免费、开源，采用 MIT 许可。TrueScale for QUADERNO 是独立项目，与富士通没有关联，也未获得其认可或赞助。FUJITSU 与 QUADERNO 是其各自权利人的商标。"),
            ],
        },
        "foot": {
            "independent": "TrueScale for QUADERNO 是独立的开源项目，与富士通没有关联，也未获得其认可或赞助。FUJITSU 与 QUADERNO 是其各自权利人的商标。",
            "license": "MIT 许可。打包的 pandoc、Typst 等组件遵循各自的许可，详见 App 的「关于」页。",
            "issues": "问题反馈", "contact": "联系作者：",
        },
    },
    "ja": {
        "meta": {
            "title": "TrueScale for QUADERNO — QUADERNO に実寸 PDF を送る Mac アプリ（EPUB・Markdown・⌃1）",
            "description": "FUJITSU QUADERNO 用の無料オープンソース Mac アプリ。テキストをコピーして ⌃1、または Finder で PDF／EPUB を右クリック。画面の実寸で組版し、USB／Wi-Fi で直接送信、SHA-256 で読み戻して照合します。",
            "keywords": "QUADERNO, FUJITSU QUADERNO A5, FMVDP51, QUADERNO PDF ぼやける, QUADERNO 実寸 PDF, QUADERNO ファイル転送 Mac, QUADERNO EPUB PDF 変換, 電子ペーパー 組版, WeChat 記事, ⌃1, macOS",
            "og_desc": "手の中のページのための組版。コピーして ⌃1 を押すと、QUADERNO に表示されます。",
            "og_alt": "TrueScale for QUADERNO —— 実寸で組版された QUADERNO A5 のページ",
            "nav_label": "ページ内ナビゲーション",
            "lang_label": "言語",
            "jsonld_summary": "FUJITSU QUADERNO の画面実寸でテキスト・Markdown・PDF・EPUB・WeChat 記事を組版し、USB または Wi-Fi で直接送信する、無料オープンソースの macOS アプリ。",
        },
        "nav": {"features": "機能一覧", "changelog": "更新履歴", "faq": "よくある質問"},
        "hero": {
            "title": "手の中のページのための組版。",
            "lead": "Mac でテキストをコピーしてキーを押すだけで、FUJITSU QUADERNO に表示されます。画面の実寸で組むので、印刷物のようにくっきり読めます。",
            "copy": "コピー", "open": "QUADERNO で開く",
            "download": "Mac 版をダウンロード", "source": "GitHub のソースコード",
            "version": "バージョン", "note": "無料・オープンソース（MIT）。Apple Silicon、macOS 14 以降。",
        },
        "why": {
            "title": "電子ペーパーで PDF がぼやける理由",
            "intro": "A4 のページを 10.3 インチの画面に縮小すると、再サンプリングで線がにじみます。足りないのは画素ではありません。TrueScale はまず画面を測り、ページをその大きさちょうどに作ります。",
            "measured": "推測ではなく実測",
            "measuredText": "1404 × 1872 ピクセルと対角 10.3 インチから算出（227.18 dpi、公表値 227 dpi との差 0.08%）し、定規で確認しました。画面上の 100 mm の線は、測るとちょうど 100 mm です。",
            "scale": "端末側で拡大縮小しない",
            "scaleText": "ページが画面そのものなので、端末はそのまま表示します。ページ上の 10.5 pt は、ペン先の下でも本物の 10.5 pt。印刷された本と同じ大きさです。",
        },
        "ways": {
            "title": "4 つの入口、どれもダイアログなし",
            "intro": "送ったファイルは端末の Received に保存され、画面に表示されます。端末上のファイルを上書きすることはありません。",
            "hotkey": "クリップボード + ⌃1",
            "hotkeyText": "テキストや Markdown をコピーして ⌃1。命名・組版・送信まで約 2 秒。",
            "finder": "Finder の右クリック",
            "finderText": "PDF・EPUB・Markdown・テキストファイルで「QUADERNO へ送信」。複数選択でき、ウインドウも開きません。",
            "books": "電子書籍と Web 記事",
            "booksText": "EPUB・MOBI・FB2・HTML、WeChat の記事にも対応。目次としおり付き。",
            "shot": "スクリーンショットを Mac へ",
            "shotText": "端末の画面を手書きごと、PNG・JPEG・実寸 PDF で保存。⌃2 かワンクリックで完了。保存先は一度決めるだけ。",
        },
        "trust": {
            "title": "書き込みを任せられる作り",
            "items": [
                ("USB / Wi-Fi で直接接続", "端末と直接やり取りします。QUADERNO PC App を開いておく必要はありません。"),
                ("読み戻して照合", "アップロードのたびに読み戻し、SHA-256 で照合してから送信完了とします。"),
                ("端末の身元を固定", "ペアリング時に端末の公開鍵を固定。異なる鍵の端末は信頼せず拒否します。"),
                ("端末のファイル", "閲覧・検索・手書きごとのダウンロード・アップロード・移動・削除。削除は必ず確認します。"),
                ("最近の送信", "すべての入口からの送信履歴。失敗したものは PDF を残し、ワンクリックで再試行。"),
                ("中文 · English · 日本語", "App と通知は 3 言語に対応し、設定で切り替えられます。"),
            ],
        },
        "caps": {
            "title": "機能一覧",
            "intro": "どの入口も同じ組版・送信パイプラインを共有します。表組みとリッチテキストの新しい扱いを含め、全体を一覧にしました。",
            "groups": [
                ("実寸組版", "ページが画面そのもの。ページ上の 10.5 pt は、ペン先の下でも本物の 10.5 pt です。", [
                    "実測した QUADERNO A5 の表示領域：156.97 × 209.30 mm、227.18 ppi",
                    "フォント・サイズ・余白・行間を調整でき、ページをプレビュー可能",
                    "pandoc → Typst → PDF。両エンジンを App に同梱",
                    "A4（FMVDP41）は 2 つの値を変更すれば利用可能",
                ]),
                ("送れるもの", "短いメモも、一冊の本も、Web 記事も同じ経路で。", [
                    "クリップボードのプレーンテキスト、Markdown、リッチ HTML 表、TSV",
                    "Finder の右クリックから PDF・EPUB・MOBI・FB2・HTML・TXT",
                    "WeChat（微信公众号）記事はリンクを貼るだけ。抽出はローカルで完結し、アカウント不要",
                    "App に直接入力・貼り付けも可能",
                ]),
                ("表組みとリッチテキスト", "AI の回答や Web ページからコピーした構造が崩れません。", [
                    "HTML 表・TSV ブロック・GFM パイプ表を組版前に正規化",
                    "列幅はセルの内容量に比例し、指定済みの揃えは保持",
                    "長い表は縮小せずページ分割し、ヘッダーを繰り返し表示",
                    "幅が広すぎる表は読みやすいリストに降级。プレーンテキストは一字も変わりません",
                ]),
                ("直接送信と照合", "相手は端末そのもの。公式クライアントは任意です。", [
                    "USB / ローカルネットワーク上の HTTPS。ペアリング時に公開鍵を固定",
                    "Document/Received/ に保存し、画面で開く",
                    "読み戻して SHA-256 を比較し、ディレクトリ一覧でも確認",
                    "転送は常に 1 本。失敗時は PDF を残して再試行でき、残骸は自動 cleanup",
                    "アップロード開始前に直結できず、公式 App が起動中の場合のみその印刷キューに降级",
                ]),
                ("ファイルとスクリーンショット", "端末に入っているものもそのまま扱えます。", [
                    "閲覧・検索・並べ替え・手書きごとのダウンロード・アップロード・移動・削除（削除は必ず確認）",
                    "⌃2 / ⌘⇧S で画面を PNG・JPEG・実寸 PDF として保存",
                    "スクリーンショットは開いている文書名とページ番号で命名",
                    "「最近の送信」に全入口の履歴。再試行と Finder で表示に対応",
                ]),
                ("アプリと作業形態", "macOS ネイティブ、かつスクリプトからも。", [
                    "メニューバー常駐、⌃1 / ⌃2 を内蔵。「ショートカット」の設定は不要",
                    "简体中文 / English / 日本語 の UI と通知",
                    "自己完結型バンドル。Homebrew もターミナルも不要",
                    "コマンドラインの book.sh / deliver.sh、ソースビルドも同じパイプライン",
                ]),
            ],
        },
        "start": {
            "title": "使い始める",
            "steps": [
                "App をダウンロードし、アプリケーションフォルダーへドラッグします。",
                "QUADERNO を USB で接続すると、設定ガイドが自動で開きます。",
                "ペアリングを移行し、セルフチェックを実行。Finder からの送信、⌃1 と ⌃2 はすぐに使えます。「ショートカット」での設定は不要です。",
            ],
            "req": [
                "Apple Silicon 搭載の Mac、macOS 14 以降。",
                "FUJITSU QUADERNO A5（FMVDP51）で実機確認済み。A4（FMVDP41）も使えますが、ページ寸法はまだ実測ではなく算出値です。",
                "同じ Mac で QUADERNO PC App が一度作成したペアリングが必要です。PIN による新規ペアリングは未対応です。",
            ],
        },
        "releases": {
            "title": "更新履歴",
            "intro": "公開済みのバージョンを新しい順に掲載し、各 GitHub Release にリンクしています。",
            "full": "GitHub で完全な変更履歴を見る",
            "entries": [
                {"tag": "1.3.0", "date": "2026-11-07", "title": "クリップボードの忠実性、表組版、送信の堅牢化", "link": REPO + "/releases/tag/v1.3.0", "items": [
                    "「·」を含むファイル名で端末が「ファイルが削除されました」と誤報する問題を修正。厳密な UTF-8 でない応答でも処理が中断しなくなりました。",
                    "⌃1 がクリップボードのリッチ HTML を読み取り、HTML 表・TSV・GFM 表を正規化。プレーンテキストと数式はそのまま保持します。",
                    "複雑な表は内容量に応じた列幅、長い表はヘッダー付きで改ページ、広すぎる表はリストに降级。認証と組版を並列化して遅延を削減し、検証チェーンは短縮していません。",
                    "同時送信はキューで直列化し、USB リンク異常を個別に検出。タイムアウト上界、空 PDF の拒否、重複送信のスキップを追加しました。",
                ]},
                {"tag": "1.2.2", "date": "2026-11-02", "title": "ショートカット、静かな Finder 送信、EPUB", "link": REPO + "/releases/tag/v1.2.2", "items": [
                    "⌃1 / ⌃2 を内蔵。Finder の右クリックで App のウインドウが開かなくなりました。",
                    "Finder の右クリックから EPUB を書籍組版で送信可能に。",
                    "スクリーンショットを文書名とページ番号で命名。ウインドウを閉じてもメニューバーに常駐。",
                ]},
                {"tag": "1.2.1", "date": "2026-11-01", "title": "より静かなアイコン", "link": REPO + "/releases/tag/v1.2.1", "items": [
                    "グレースケールの紙と左上の斜体小文字 q に変更。サイトのアイコンと favicon も同じデザインに。",
                ]},
                {"tag": "1.2.0", "date": "2026-11-01", "title": "直接送信と TrueScale への改名", "link": REPO + "/releases/tag/v1.2.0", "items": [
                    "Quaderno Converter から改名。初回起動時に設定を移行。",
                    "USB / LAN からの直接送信、公開鍵の固定、SHA-256 の読み戻し、アップロード前に限った公式クライアントへの降级。",
                    "Finder 右クリック送信、简体中文 / English / 日本語 UI、初回ガイド、端末ファイル、スクリーンショット書き出し。",
                ]},
            ],
        },
        "faq": {
            "title": "よくある質問",
            "intro": "寸法、対応環境、対応する入力、送信の安全性についての短い回答です。",
            "items": [
                ("QUADERNO で PDF がぼやけるのはなぜですか？どう直せますか？",
                 "多くの場合、A4 / Letter のページが 10.3 インチ画面に縮小され、再サンプリングで線がにじむのが原因です。TrueScale は QUADERNO A5 の実測表示領域（156.97 × 209.30 mm）に合わせてページを作るため、端末は拡大縮小せず 227 ppi をそのまま表示します。キャリブレーションページでどの電子ペーパーでも 1:1 を確認できます。"),
                ("QUADERNO PC App を開かずに Mac から QUADERNO へファイルを送れますか？",
                 "はい。TrueScale は USB またはローカルネットワーク上の HTTPS で端末と直接通信し、公式 App から一度取り込んだペアリングを再利用します。以後は公式クライアントを起動する必要はありません。アップロード開始前に直結できず、公式 App が起動している場合のみ、その印刷キューに降级します。"),
                ("対応する入力は？EPUB、WeChat 記事、AI の回答に含まれる表も送れますか？",
                 "クリップボードのプレーンテキスト・Markdown・リッチ HTML、Finder の PDF・EPUB・MOBI・FB2・HTML・TXT、WeChat（微信公众号）記事のリンク、App への直接入力に対応します。AI の回答に含まれる表は HTML・TSV・GFM パイプ表から正規化し、列幅と揃えを保持します。WeChat 記事の抽出は Mac 上で完結します。"),
                ("QUADERNO A5（FMVDP51）の表示領域と解像度は？",
                 "対角 10.3 インチ、1404 × 1872 ピクセル、227.18 ppi、表示領域 156.97 × 209.30 mm です。画面に描いた 100 mm の線を定規で測るとちょうど 100 mm になります。ダウンロードできるキャリブレーションページで、他の端末でも同じ 1:1 を確認できます。"),
                ("A4（FMVDP41）、Intel Mac、Windows でも使えますか？",
                 "A4 は使えますが、ページ寸法はまだ実測ではなく算出値なので、使用前に 2 つの値を変更してください。配布バイナリは Apple Silicon と macOS 14 以降のみ対応です。Intel Mac はソースから自機向けにビルドできます。Windows は非対応です。"),
                ("送信すると QUADERNO 内のファイルが上書き・削除されますか？",
                 "いいえ。書き込みは Document/Received/ への保存と画面で開く処理だけです。移動と削除は「端末のファイル」で明示的に操作した場合のみで、必ず確認します。各アップロードは端末から読み戻して SHA-256 を比較し、一致して初めて送信完了になります。"),
                ("無料ですか？富士通と関係はありますか？",
                 "MIT ライセンスの無料オープンソースです。TrueScale for QUADERNO は独立したプロジェクトで、富士通とは関係がなく、承認や支援も受けていません。FUJITSU および QUADERNO はそれぞれの権利者の商標です。"),
            ],
        },
        "foot": {
            "independent": "TrueScale for QUADERNO は独立したオープンソースプロジェクトであり、富士通とは関係がなく、富士通による承認や支援も受けていません。FUJITSU および QUADERNO は、それぞれの権利者の商標です。",
            "license": "MIT ライセンス。同梱の pandoc・Typst などはそれぞれのライセンスに従います。詳細は App の「情報」画面をご覧ください。",
            "issues": "問題を報告", "contact": "連絡先：",
        },
    },
}


# Independent Traditional Chinese copy is checked in: CI needs no conversion tool.
CONTENT["en"]["tribute"] = {
    "title": "With appreciation for FUJITSU QUADERNO.",
    "text": "We admire the restraint of its industrial design: information technology serving reading, writing and thought. TrueScale shares that spirit, giving digital words the care of a printed page.",
}
CONTENT["zh"]["tribute"] = {
    "title": "向 FUJITSU QUADERNO 致敬。",
    "text": "我们欣赏它克制的工业设计，让信息技术恰当地服务于阅读、书写与思考。TrueScale 希望延续这种理念，让数字内容以适合纸页的方式呈现。",
}
CONTENT["ja"]["tribute"] = {
    "title": "FUJITSU QUADERNO への敬意を込めて。",
    "text": "その控えめな工業デザインと、読む・書く・考えることに寄り添う情報技術に敬意を表します。TrueScale もその精神を大切に、デジタルの言葉を紙のページのように丁寧に整えます。",
}
CONTENT["en"]["hero"]["title"] = "A little more care for every page."
CONTENT["zh"]["hero"]["title"] = "让每一页，\n都值得静心阅读。"
CONTENT["ja"]["hero"]["title"] = "一ページずつ、\n心地よく読むために。"
CONTENT["en"]["hero"]["lead"] = "From words on your Mac to a page on your QUADERNO. Thoughtful typography, true physical size, and a quiet place to read."
CONTENT["zh"]["hero"]["lead"] = "从 Mac 上的文字，到 QUADERNO 上的一页。合宜的字体、真实的尺寸，让阅读回到从容。"
CONTENT["ja"]["hero"]["lead"] = "Mac の言葉を、QUADERNO の一ページへ。読みやすい書体と実際のページサイズで、落ち着いた読書の時間を。"
CONTENT["en"]["meta"]["jsonld_summary"] = "A free, open-source Mac app that typesets text, Markdown and EPUB for QUADERNO and delivers documents directly over USB or Wi-Fi. Existing PDFs can be sent directly."
CONTENT["zh"]["meta"]["jsonld_summary"] = "免费的开源 Mac 应用，为 QUADERNO 排版文本、Markdown 和 EPUB，通过 USB 或 Wi-Fi 直接投递文档。现有 PDF 支持直接投递。"
CONTENT["ja"]["meta"]["jsonld_summary"] = "テキスト、Markdown、EPUB を QUADERNO 向けに組版し、USB または Wi-Fi で直接送信する無料のオープンソース Mac アプリです。既存の PDF も直接送信できます。"
CONTENT["zh-hant"] = json.loads((SITE / "content-zh-hant.json").read_text(encoding="utf-8"))


# Website deployments have their own dated entries; they do not change the App version.
WEBSITE_UPDATE = {
    "en": ("Website", "A brighter moment for reading", "Website updates and App releases, newest first.", [
        "The homepage now uses the selected Katya Wolf / Pexels reading photograph, brightened with AI-assisted tonal editing; the original is retained.",
        "Portrait cropping and soft edges are adapted for desktop and mobile. Photographer credit, the license and processing notes are included.",
        "This website update applies to all four languages. The downloadable App remains version 1.3.0.",
    ]),
    "zh": ("官网更新", "让阅读画面更明亮", "官网更新与 App 发行记录，按时间倒序排列。", [
        "首页采用选定的 Katya Wolf / Pexels 阅读照片，经 AI 辅助调亮曝光与阴影，原片保留。",
        "调整桌面与手机的竖幅裁切和柔和边缘，补齐摄影署名、许可及图片处理记录。",
        "简体中文、正體中文、English、日本語四语同步；本次为官网更新，App 下载版本仍为 1.3.0。",
    ]),
    "zh-hant": ("官網更新", "讓閱讀畫面更明亮", "官網更新與 App 發行紀錄，按時間倒序排列。", [
        "首頁採用選定的 Katya Wolf / Pexels 閱讀照片，經 AI 輔助調亮曝光與陰影，原片保留。",
        "調整桌面與手機的直幅裁切和柔和邊緣，補齊攝影署名、授權及圖片處理紀錄。",
        "簡體中文、正體中文、English、日本語四語同步；本次為官網更新，App 下載版本仍為 1.3.0。",
    ]),
    "ja": ("Web サイト", "読書のひとときを、明るく", "Web サイトの更新と App のリリースを、新しい順に掲載しています。", [
        "トップページの写真を Katya Wolf / Pexels の読書シーンに変更。AI を使って露出と暗部を明るく調整し、元の写真も保存しています。",
        "パソコンとスマートフォンに合わせて縦長写真の表示範囲と輪郭を調整。撮影者、ライセンス、加工記録を明記しました。",
        "4 言語のページを同時に更新。今回は Web サイトの更新で、ダウンロードできる App は引き続き 1.3.0 です。",
    ]),
}
for language, (tag, title, intro, items) in WEBSITE_UPDATE.items():
    CONTENT[language]["releases"]["intro"] = intro
    CONTENT[language]["releases"]["entries"].insert(0, {
        "tag": tag, "date": "2026-11-10", "title": title,
        "link": CHANGELOG, "items": items,
    })


# Source changes are explicitly separated from downloadable App releases.
USB_SOURCE_UPDATE = {
    "en": ("Source update", "USB connection recovery", [
        "Fixes a yellow connection status that could persist after a USB mode-switch command. Recovery now follows observed readiness and retries with backoff.",
        "Shares recovery between connection monitoring and delivery, adds serial-write and process deadlines, and yields to active deliveries.",
        "Verified locally with automated fault scenarios and a connected QUADERNO. These changes are in the source; the downloadable App remains 1.3.0 and does not yet include this fix.",
    ]),
    "zh": ("源码更新", "USB 连接自动恢复", [
        "修复发送 USB 模式切换命令后可能一直显示黄色的问题：按实际就绪状态确认连接，失败后退避重试。",
        "连接监视与投递共用恢复逻辑，串口发送及恢复进程均设超时，后台恢复会避让正在进行的投递。",
        "已通过本地故障场景测试和 QUADERNO 实机连接验证。修复已更新至源码；当前下载仍为 1.3.0，尚未包含本次修复。",
    ]),
    "zh-hant": ("原始碼更新", "USB 連線自動復原", [
        "修正送出 USB 模式切換指令後可能持續顯示黃色的問題：依實際就緒狀態確認連線，失敗後逐步延長重試間隔。",
        "連線監視與傳送共用復原邏輯，序列埠傳送及復原程序均設逾時，背景復原會避開正在進行的傳送。",
        "已通過本機故障情境測試及 QUADERNO 實機連線驗證。修正已更新至原始碼；目前下載仍為 1.3.0，尚未包含本次修正。",
    ]),
    "ja": ("ソース更新", "USB 接続の自動復旧", [
        "USB モード切替コマンドの送信後も接続表示が黄色のままになる問題を修正。実際の接続状態を確認し、失敗時は間隔を延ばして再試行します。",
        "接続監視と送信で復旧処理を共通化。シリアル送信と復旧プロセスにタイムアウトを設け、送信中はバックグラウンド復旧を見送ります。",
        "ローカルの障害テストと QUADERNO 実機で検証済みです。修正はソースに反映されています。ダウンロード版は引き続き 1.3.0 で、今回の修正はまだ含まれません。",
    ]),
}
for language, (tag, title, items) in USB_SOURCE_UPDATE.items():
    CONTENT[language]["releases"]["entries"].insert(0, {
        "tag": tag, "date": "2026-11-12", "title": title,
        "link": CHANGELOG + "#source-update--2026-11-12", "items": items,
    })


# Localized search snippets describe released capabilities rather than future PDF reflow.
SEARCH_COPY = {
    "en": {
        "title": "TrueScale for QUADERNO — Mac PDF Transfer & EPUB Typesetting",
        "description": "Send PDFs from Mac to FUJITSU QUADERNO over USB or Wi-Fi. Typeset EPUB, Markdown and text for e-paper. Free, open-source macOS app with verified delivery.",
        "label": "PDF transfer & EPUB typesetting for Mac",
        "intro": "An oversized page can make text too small on e-paper. TrueScale typesets text, Markdown and EPUB for your reader. Existing PDFs are transferred with their original layout.",
        "answer": "A4 and Letter pages often make text smaller when fitted onto a QUADERNO A5. TrueScale can typeset text, Markdown and EPUB for the reader's page size. Existing PDF files are transferred with their layout preserved; automatic PDF text extraction and reflow are not available in the current release.",
        "map": "Sitemap",
    },
    "zh": {
        "title": "TrueScale for QUADERNO｜Mac 传 PDF、EPUB 电子纸排版工具",
        "description": "从 Mac 通过 USB 或 Wi-Fi 向富士通 QUADERNO 传 PDF，为 EPUB、Markdown 和文字按电子纸尺寸排版。免费开源，支持快捷键投递与传输校验。现有 PDF 保留原版式。",
        "label": "Mac 上的 QUADERNO 文件投递与电子书排版工具",
        "intro": "过大的页面放到电子纸上，文字容易显得细小。TrueScale 为文本、Markdown 与 EPUB 按阅读页面排版；现有 PDF 则保留原版式直接投递。",
        "answer": "A4 或 Letter 页面缩放到 QUADERNO A5 时，文字往往会变小。TrueScale 可以为文本、Markdown 与 EPUB 按目标阅读页面重新排版。已有 PDF 保留原版式投递；当前发行版尚不支持自动提取 PDF 正文并重排。",
        "map": "网站地图",
    },
    "zh-hant": {
        "title": "TrueScale for QUADERNO｜Mac 傳 PDF、EPUB 電子紙排版工具",
        "description": "從 Mac 透過 USB 或 Wi-Fi 向富士通 QUADERNO 傳 PDF，為 EPUB、Markdown 與文字按電子紙尺寸排版。免費開放原始碼，支援快速鍵傳送與傳輸驗證。現有 PDF 保留原版面。",
        "label": "Mac 上的 QUADERNO 檔案傳送與電子書排版工具",
        "intro": "過大的頁面放到電子紙上，文字容易顯得細小。TrueScale 為文字、Markdown 與 EPUB 按閱讀頁面排版；現有 PDF 則保留原版面直接傳送。",
        "answer": "A4 或 Letter 頁面縮放到 QUADERNO A5 時，文字往往會變小。TrueScale 可以為文字、Markdown 與 EPUB 按目標閱讀頁面重新排版。已有 PDF 保留原版面傳送；目前發行版尚不支援自動擷取 PDF 正文並重新排版。",
        "map": "網站地圖",
    },
    "ja": {
        "title": "TrueScale for QUADERNO｜Mac から PDF 転送・EPUB 組版",
        "description": "Mac から富士通 QUADERNO へ USB・Wi-Fi で PDF を転送。EPUB、Markdown、テキストを電子ペーパー向けに組版する無料オープンソースアプリです。既存 PDF のレイアウトを保持し、転送後にデータを照合します。",
        "label": "Mac から QUADERNO へ。PDF 転送と電子書籍の組版",
        "intro": "大きな用紙を電子ペーパーに合わせると、文字が小さくなりがちです。TrueScale はテキスト・Markdown・EPUB を読書用のページに組版。既存の PDF はレイアウトを保って転送します。",
        "answer": "A4 や Letter のページを QUADERNO A5 に合わせると、文字が小さくなることがあります。TrueScale はテキスト、Markdown、EPUB を端末のページサイズに合わせて組版します。既存の PDF はレイアウトを保持して転送します。現在のリリースには PDF 本文の自動抽出・再組版機能はありません。",
        "map": "サイトマップ",
    },
}
for language, copy in SEARCH_COPY.items():
    meta = CONTENT[language]["meta"]
    meta["title"] = copy["title"]
    meta["description"] = copy["description"]
    meta["og_desc"] = copy["description"]
    CONTENT[language]["why"]["intro"] = copy["intro"]
    question = CONTENT[language]["faq"]["items"][0][0]
    CONTENT[language]["faq"]["items"][0] = (question, copy["answer"])


for language, note in {
    "en": "Improve localized search snippets, canonical/hreflang validation and page/app structured data. Deliver smaller responsive WebP images while preserving the selected photograph and icon.",
    "zh": "完善四语搜索摘要、canonical/hreflang 校验及网页/App 结构化数据；首屏照片与图标增加响应式 WebP，减小下载体积。",
    "zh-hant": "完善四語搜尋摘要、canonical/hreflang 驗證及網頁/App 結構化資料；首屏照片與圖示增加響應式 WebP，減少下載大小。",
    "ja": "4 言語の検索用メタデータ、canonical・hreflang 検証、Web ページと App の構造化データを改善。写真とアイコンをレスポンシブ WebP で軽量化しました。",
}.items():
    CONTENT[language]["releases"]["entries"][0]["items"].append(note)


def esc(value: str) -> str:
    return html.escape(str(value), quote=True)


def validate() -> None:
    """Keep the four localizations structurally identical and complete."""
    def shape(node, path="root"):
        if isinstance(node, dict):
            return ("dict", tuple(sorted((k, shape(v, path + "." + k)) for k, v in node.items())))
        if isinstance(node, (list, tuple)):
            return ("list", len(node), tuple(shape(v, path + "[]") for v in node))
        return ("str",)

    base = shape(CONTENT["en"])
    for lang, data in CONTENT.items():
        if shape(data) != base:
            raise SystemExit(f"content shape mismatch for {lang}: expected en structure")
        if not data["faq"]["items"] or not data["caps"]["groups"] or not data["releases"]["entries"]:
            raise SystemExit(f"empty SEO-bearing section for {lang}")


VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}


class TagBalance(HTMLParser):
    """The system tidy(1) is an HTML4 build; balance HTML5 tags ourselves."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.errors: list[str] = []

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag: str) -> None:
        if tag in VOID:
            return
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()
        elif tag in self.stack:
            self.errors.append(f"nesting: </{tag}> closed out of order")
            while self.stack and self.stack.pop() != tag:
                pass
        else:
            self.errors.append(f"unexpected </{tag}>")


def validate_markup(files: dict[Path, str]) -> None:
    """Assert the SEO invariants on every generated page, not just file equality."""
    titles, descriptions = set(), set()
    expected_alternates = {info["hreflang"]: SITE_URL + info["dir"] for info in LANGS.values()}
    expected_alternates.update({"zh-CN": SITE_URL + "zh/", "x-default": SITE_URL})
    for lang, info in LANGS.items():
        path = SITE / (info["dir"] + "index.html")
        doc = files[path]
        c = CONTENT[lang]
        problems: list[str] = []

        title = re.findall(r"<title>(.*?)</title>", doc)
        description = re.findall(r'<meta name="description" content="([^"]+)">', doc)
        if len(title) != 1 or title[0] in titles or "QUADERNO" not in title[0]:
            problems.append("missing, duplicate or unrelated search title")
        if len(description) != 1 or description[0] in descriptions:
            problems.append("missing or duplicate search description")
        titles.update(title)
        descriptions.update(description)
        crawler_directives = re.findall(r'<meta name="(?:robots|googlebot)" content="([^"]+)">', doc, re.I)
        if any(re.search(r"\b(?:noindex|nofollow|none)\b", value, re.I) for value in crawler_directives):
            problems.append("page accidentally blocks indexing or link discovery")
        if doc.count('<link rel="canonical"') != 1:
            problems.append("canonical must appear exactly once")
        actual_alternates = dict(re.findall(r'<link rel="alternate" hreflang="([^"]+)" href="([^"]+)">', doc))
        if actual_alternates != expected_alternates:
            problems.append("language alternates must point to all canonical locales")

        if f'<html lang="{info["lang"]}">' not in doc:
            problems.append("missing html lang")
        if doc.count("<h1>") != 1:
            problems.append("h1 must appear exactly once")
        if f'<link rel="canonical" href="{SITE_URL}{info["dir"]}">' not in doc:
            problems.append("canonical mismatch")
        for code in ("en", "zh-Hans", "zh-CN", "zh-Hant", "ja", "x-default"):
            if f'hreflang="{code}"' not in doc:
                problems.append("missing hreflang " + code)
        for section in ("features", "changelog", "faq"):
            if f'id="{section}"' not in doc:
                problems.append("missing section " + section)
        if doc.count('<article class="capability">') != len(c["caps"]["groups"]):
            problems.append("capability count")
        if doc.count('<li class="release">') != len(c["releases"]["entries"]):
            problems.append("release count")
        if doc.count('<details class="qa"') != len(c["faq"]["items"]):
            problems.append("FAQ count")
        if "data-i18n" in doc:
            problems.append("JS-injected copy survived")
        if 'class="device"' in doc:
            problems.append("device mockup is back in the hero")
        if re.search(r"<img[^>]+device-page\.png", doc):
            problems.append("device screenshot bitmap is back in the hero")

        balance = TagBalance()
        balance.feed(doc)
        problems.extend(balance.errors)
        if balance.stack:
            problems.append("unclosed tags " + ", ".join(balance.stack[-5:]))

        block = re.search(r'<script type="application/ld\+json">\s*(.*?)\s*</script>', doc, re.S)
        if not block:
            problems.append("missing JSON-LD")
        else:
            graph = json.loads(block.group(1))["@graph"]
            if {n["@type"] for n in graph} != {"WebSite", "WebPage", "SoftwareApplication", "FAQPage"}:
                problems.append("JSON-LD graph types")
            app = next(n for n in graph if n["@type"] == "SoftwareApplication")
            page = next(n for n in graph if n["@type"] == "WebPage")
            if app["softwareVersion"] != LATEST or app["dateModified"] != APP_RELEASE_DATE:
                problems.append("software metadata must describe the released App")
            if app.get("screenshot") == SITE_URL + "assets/device-page.png":
                problems.append("do not describe a PDF sample as an App screenshot")
            if page["url"] != SITE_URL + info["dir"] or page["inLanguage"] != info["lang"]:
                problems.append("WebPage locale or URL mismatch")
            if page["name"] != c["meta"]["title"] or page["description"] != c["meta"]["description"]:
                problems.append("WebPage metadata differs from visible search metadata")
            faq_node = next(n for n in graph if n["@type"] == "FAQPage")
            if len(faq_node["mainEntity"]) != len(c["faq"]["items"]):
                problems.append("JSON-LD FAQ count")
            for node, (question, answer) in zip(faq_node["mainEntity"], c["faq"]["items"]):
                if node["name"] != question or node["acceptedAnswer"]["text"] != answer:
                    problems.append("JSON-LD FAQ text drift")

        for ref in re.findall(r'(?:href|src)="([^"]+)"', doc):
            if ref.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = (path.parent / ref.split("#")[0].split("?")[0]).resolve()
            generated = target in files or target / "index.html" in files
            if not target.exists() and not generated:
                problems.append("missing local asset " + ref)
        for ref in re.findall(r'(?:srcset|imagesrcset)="([^"]+)"', doc):
            for candidate in ref.split(","):
                resource = candidate.strip().split()[0]
                if not (path.parent / resource).resolve().is_file():
                    problems.append("missing responsive image " + resource)

        if problems:
            raise SystemExit(f"{lang} page failed validation: " + "; ".join(problems))

    ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9", "x": "http://www.w3.org/1999/xhtml"}
    xml_root = ET.fromstring(files[SITE / "sitemap.xml"])
    locs = {node.text for node in xml_root.findall("s:url/s:loc", ns)}
    expected = {SITE_URL + LANGS[l]["dir"] for l in LANGS}
    if locs != expected:
        raise SystemExit("sitemap URLs do not match the localized pages")
    for node in xml_root.findall("s:url", ns):
        alternates = {link.attrib["hreflang"]: link.attrib["href"] for link in node.findall("x:link", ns)}
        if alternates != expected_alternates:
            raise SystemExit("sitemap language alternates differ from the HTML pages")
    if f"Sitemap: {SITE_URL}sitemap.xml" not in files[SITE / "robots.txt"]:
        raise SystemExit("robots.txt does not advertise the sitemap")
    if not (SITE / "assets" / "og-card.png").exists():
        raise SystemExit("og-card.png missing; run site/make-og-card.py")
    css = (SITE / "assets" / "site.css").read_text(encoding="utf-8")
    if "--band" in css or ".device {" in css:
        raise SystemExit("device mockup styles are back in site.css")


def json_ld(lang: str) -> str:
    c = CONTENT[lang]
    canonical = SITE_URL + LANGS[lang]["dir"]
    graph = [
        {
            "@type": "WebSite",
            "@id": SITE_URL + "#website",
            "url": SITE_URL,
            "name": "TrueScale for QUADERNO",
            "inLanguage": ["en", "zh-Hans", "zh-Hant", "ja"],
            "publisher": {"@type": "Person", "name": "leekaomin", "email": "leekaomin@foxmail.com"},
        },
        {
            "@type": "SoftwareApplication",
            "@id": SITE_URL + "#app",
            "name": "TrueScale for QUADERNO",
            "alternateName": ["TrueScale", "True Scale", "TrueScale PDF", "QUADERNO PDF 转换器"],
            "url": canonical,
            "description": c["meta"]["jsonld_summary"],
            "applicationCategory": "UtilitiesApplication",
            "applicationSubCategory": "E-ink / e-paper document tools",
            "operatingSystem": "macOS 14 or later (Apple Silicon)",
            "softwareVersion": LATEST,
            "dateModified": APP_RELEASE_DATE,
            "isAccessibleForFree": True,
            "inLanguage": ["en", "zh-Hans", "ja"],
            "license": REPO + "/blob/master/LICENSE",
            "releaseNotes": REPO + "/releases/tag/v" + LATEST,
            "downloadUrl": RELEASES,
            "installUrl": RELEASES,
            "image": SITE_URL + "assets/icon.png",
            "featureList": [g[0] for g in c["caps"]["groups"]],
            "author": {"@type": "Person", "name": "leekaomin", "email": "leekaomin@foxmail.com"},
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD", "availability": "https://schema.org/InStock"},
            "sameAs": [REPO, REPO + "/releases", CHANGELOG],
        },
        {
            "@type": "WebPage",
            "@id": canonical + "#webpage",
            "url": canonical,
            "name": c["meta"]["title"],
            "description": c["meta"]["description"],
            "inLanguage": LANGS[lang]["lang"],
            "isPartOf": {"@id": SITE_URL + "#website"},
            "mainEntity": {"@id": SITE_URL + "#app"},
            "hasPart": {"@id": canonical + "#faq"},
            "dateModified": LASTMOD,
            "primaryImageOfPage": {
                "@type": "ImageObject", "url": SITE_URL + "assets/og-card.png",
                "width": 1200, "height": 630,
            },
        },
        {
            "@type": "FAQPage",
            "@id": canonical + "#faq",
            "inLanguage": LANGS[lang]["lang"],
            "mainEntity": [
                {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}}
                for q, a in c["faq"]["items"]
            ],
        },
    ]
    payload = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False, indent=2)
    return payload.replace("</", "<\\/")


def render(lang: str) -> str:
    c = CONTENT[lang]
    m, nav, hero = c["meta"], c["nav"], c["hero"]
    why, ways, trust = c["why"], c["ways"], c["trust"]
    caps, start, releases, faq, foot = c["caps"], c["start"], c["releases"], c["faq"], c["foot"]
    info = LANGS[lang]
    base = "../" if info["dir"] else ""
    canonical = SITE_URL + info["dir"]
    og_image = SITE_URL + "assets/og-card.png"

    hreflang = "\n".join(
        f'<link rel="alternate" hreflang="{code}" href="{SITE_URL}{suffix}">'
        for code, suffix in [("en", ""), ("zh-Hans", "zh/"), ("zh-CN", "zh/"), ("zh-Hant", "zh-hant/"), ("ja", "ja/"), ("x-default", "")]
    )
    locale_alternates = "\n".join(
        f'<meta property="og:locale:alternate" content="{LANGS[l]["locale"]}">'
        for l in LANGS if l != lang
    )
    language_links = "\n".join(
        f'<a href="{base}{LANGS[l]["dir"]}" hreflang="{LANGS[l]["hreflang"]}" lang="{LANGS[l]["lang"]}"'
        + (' aria-current="page"' if l == lang else "")
        + f'>{esc(LANGS[l]["label"])}</a>'
        for l in ("zh", "zh-hant", "en", "ja")
    )

    trust_cards = "\n".join(
        f'          <div class="feature"><h3>{esc(h)}</h3><p>{esc(p)}</p></div>' for h, p in trust["items"]
    )
    capability_cards = "\n".join(
        '          <article class="capability"><h3>' + esc(h) + '</h3><p>' + esc(p) + '</p><ul>'
        + "".join(f"<li>{esc(item)}</li>" for item in items) + "</ul></article>"
        for h, p, items in caps["groups"]
    )
    release_items = []
    for r in releases["entries"]:
        tag = f'<a href="{esc(r["link"])}">{esc(r["tag"])}</a>' if r["link"] else esc(r["tag"])
        release_items.append(
            '          <li class="release"><div class="release-head">'
            f'<span class="tag">{tag}</span><time datetime="{esc(r["date"])}">{esc(r["date"])}</time>'
            f'</div><h3>{esc(r["title"])}</h3><ul>'
            + "".join(f"<li>{esc(item)}</li>" for item in r["items"])
            + "</ul></li>"
        )
    faq_items = "\n".join(
        '          <details class="qa"' + (" open" if i == 0 else "") + ">"
        f'<summary>{esc(q)}</summary><p>{esc(a)}</p></details>'
        for i, (q, a) in enumerate(faq["items"])
    )
    steps = "\n".join(f'          <li><div>{esc(s)}</div></li>' for s in start["steps"])
    reqs = "\n".join(f'          <li>{esc(r)}</li>' for r in start["req"])

    parts = [rf'''<!doctype html>
<html lang="{info["lang"]}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(m["title"])}</title>
<meta name="description" content="{esc(m["description"])}">
<meta name="author" content="leekaomin">
<meta name="robots" content="index, follow, max-snippet:-1, max-image-preview:large, max-video-preview:-1">
<meta name="theme-color" content="#f7f8fa">
<link rel="canonical" href="{canonical}">
{hreflang}
<link rel="icon" href="{base}assets/favicon.png">
<link rel="stylesheet" href="{base}assets/site.css?v={CSS_VERSION}">
<link rel="preload" as="image" type="image/webp" href="{base}assets/reading-coffee-8715935-bright.webp" imagesrcset="{base}assets/reading-coffee-8715935-bright-640.webp 640w, {base}assets/reading-coffee-8715935-bright.webp 1024w" imagesizes="(max-width: 860px) calc(100vw - 32px), (max-width: 1200px) 58vw, 672px" fetchpriority="high">
<link rel="sitemap" type="application/xml" href="{base}sitemap.xml">
<meta property="og:type" content="website">
<meta property="og:site_name" content="TrueScale for QUADERNO">
<meta property="og:locale" content="{info["locale"]}">
{locale_alternates}
<meta property="og:title" content="{esc(m["title"])}">
<meta property="og:description" content="{esc(m["og_desc"])}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{og_image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{esc(m["og_alt"])}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(m["title"])}">
<meta name="twitter:description" content="{esc(m["og_desc"])}">
<meta name="twitter:image" content="{og_image}">
<script type="application/ld+json">
{json_ld(lang)}
</script>
</head>
<body>
<div class="wrap">
  <header>
    <a class="brand" href="{base}index.html"><img src="{base}assets/favicon.png" alt="" width="32" height="32"><span>TrueScale for QUADERNO</span></a>
    <nav class="topnav" aria-label="{esc(m["nav_label"])}">
      <a href="#features">{esc(nav["features"])}</a>
      <a href="#changelog">{esc(nav["changelog"])}</a>
      <a href="#faq">{esc(nav["faq"])}</a>
    </nav>
    <nav class="langs" aria-label="{esc(m["lang_label"])}">
{language_links}
    </nav>
  </header>

  <main>
    <div class="hero">
      <div class="hero-photo" aria-hidden="true"><picture>
        <source type="image/webp" srcset="{base}assets/reading-coffee-8715935-bright-640.webp 640w, {base}assets/reading-coffee-8715935-bright.webp 1024w" sizes="(max-width: 860px) calc(100vw - 32px), (max-width: 1200px) 58vw, 672px">
        <img src="{base}assets/reading-coffee-8715935-bright.jpg" alt="" width="1024" height="1536" fetchpriority="high" decoding="async">
      </picture></div>
      <div class="hero-copy">
      <img class="hero-icon" src="{base}assets/icon-384.webp" srcset="{base}assets/icon-192.webp 192w, {base}assets/icon-384.webp 384w" sizes="(max-width: 860px) 112px, 144px" alt="TrueScale" width="144" height="144">
      <p class="product-label">{esc(SEARCH_COPY[lang]["label"])}</p>
      <h1>{esc(hero["title"])}</h1>
      <p class="lead">{esc(hero["lead"])}</p>
      <div class="flow" aria-hidden="true">
        <span>{esc(hero["copy"])}</span><span>→</span><span class="key">⌃1</span><span>→</span><span>{esc(hero["open"])}</span>
      </div>
      <div class="actions">
        <a class="button primary" href="{RELEASES}">{esc(hero["download"])}</a>
        <a class="button secondary" href="{REPO}">{esc(hero["source"])}</a>
      </div>
      <p class="note">{esc(hero["version"])} <span id="version">{LATEST}</span> · {esc(hero["note"])}</p>
      </div>
    </div>

    <section id="why">
      <div class="wrap">
        <h2>{esc(why["title"])}</h2>
        <p class="intro">{esc(why["intro"])}</p>
        <div class="why">
          <div class="panel">
            <div class="figure">156.97 × 209.30 mm</div>
            <h3>{esc(why["measured"])}</h3>
            <p>{esc(why["measuredText"])}</p>
          </div>
          <div class="panel">
            <div class="figure">1 : 1</div>
            <h3>{esc(why["scale"])}</h3>
            <p>{esc(why["scaleText"])}</p>
          </div>
        </div>
      </div>
    </section>

    <section id="ways">
      <div class="wrap">
        <h2>{esc(ways["title"])}</h2>
        <p class="intro">{esc(ways["intro"])}</p>
        <div class="ways">
          <div class="way">
            <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="7" width="18" height="12" rx="2"/><path d="M7 11h2M11 11h2M15 11h2M7 15h10"/></svg>
            <h3>{esc(ways["hotkey"])}</h3>
            <p>{esc(ways["hotkeyText"])}</p>
          </div>
          <div class="way">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
            <h3>{esc(ways["finder"])}</h3>
            <p>{esc(ways["finderText"])}</p>
          </div>
          <div class="way">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4h10l4 4v12H5z"/><path d="M14 4v5h5M8 13h8M8 17h6"/></svg>
            <h3>{esc(ways["books"])}</h3>
            <p>{esc(ways["booksText"])}</p>
          </div>
          <div class="way">
            <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="14" rx="2"/><circle cx="12" cy="12" r="3.2"/><path d="M8 3h3"/></svg>
            <h3>{esc(ways["shot"])}</h3>
            <p>{esc(ways["shotText"])}</p>
          </div>
        </div>
      </div>
    </section>

    <section id="trust">
      <div class="wrap">
        <h2>{esc(trust["title"])}</h2>
        <div class="features">
{trust_cards}
        </div>
      </div>
    </section>

    <section id="features">
      <div class="wrap">
        <h2>{esc(caps["title"])}</h2>
        <p class="intro">{esc(caps["intro"])}</p>
        <div class="capabilities">
{capability_cards}
        </div>
      </div>
    </section>

    <section id="start">
      <div class="wrap">
        <h2>{esc(start["title"])}</h2>
        <ol class="steps">
{steps}
        </ol>
        <ul class="requirements">
{reqs}
        </ul>
      </div>
    </section>

    <section id="changelog">
      <div class="wrap">
        <h2>{esc(releases["title"])}</h2>
        <p class="intro">{esc(releases["intro"])} <a href="{CHANGELOG}">{esc(releases["full"])}</a></p>
        <ol class="releases">
{chr(10).join(release_items)}
        </ol>
      </div>
    </section>

    <section id="faq">
      <div class="wrap">
        <h2>{esc(faq["title"])}</h2>
        <p class="intro">{esc(faq["intro"])}</p>
        <div class="faq">
{faq_items}
        </div>
      </div>
    </section>
    <section class="tribute">
      <h2>{esc(c["tribute"]["title"])}</h2>
      <p>{esc(c["tribute"]["text"])}</p>
    </section>
  </main>

  <footer>
    <p>{esc(foot["independent"])}</p>
    <p>{esc(foot["license"])}</p>
    <p><a href="{REPO}">github.com/leekaomin380/eink-truescale-pdf</a> · <a href="{REPO}/issues">{esc(foot["issues"])}</a> · <a href="{base}sitemap.xml">{esc(SEARCH_COPY[lang]["map"])}</a></p>
    <p>{esc(foot["contact"])}<a href="mailto:leekaomin@foxmail.com">leekaomin@foxmail.com</a></p>
    <p class="photo-credit">Photo: <a href="https://www.pexels.com/photo/woman-reading-a-book-and-having-coffee-8715935/">Katya Wolf / Pexels</a> · <a href="https://www.pexels.com/license/">Pexels License</a></p>
  </footer>
</div>

<script>
// 页面里写的是发布时的版本；能连上 GitHub 时换成最新 Release，失败就保留原值。
fetch("https://api.github.com/repos/leekaomin380/eink-truescale-pdf/releases/latest")
  .then(r => r.ok ? r.json() : null)
  .then(release => {{
    const tag = release && /^v?(\d+\.\d+\.\d+)$/.exec(release.tag_name || "");
    if (tag) document.getElementById("version").textContent = tag[1];
  }})
  .catch(() => {{}});
</script>
</body>
</html>
''']
    return parts[0]


def sitemap() -> str:
    alternates = "\n".join(
        f'    <xhtml:link rel="alternate" hreflang="{code}" href="{SITE_URL}{suffix}"/>'
        for code, suffix in [("en", ""), ("zh-Hans", "zh/"), ("zh-CN", "zh/"), ("zh-Hant", "zh-hant/"), ("ja", "ja/"), ("x-default", "")]
    )
    urls = []
    for lang, info in LANGS.items():
        priority = "1.0" if lang == "en" else "0.9"
        urls.append(
            f'  <url>\n    <loc>{SITE_URL}{info["dir"]}</loc>\n'
            f'    <lastmod>{LASTMOD}</lastmod>\n    <changefreq>weekly</changefreq>\n'
            f'    <priority>{priority}</priority>\n{alternates}\n  </url>'
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"\n'
        '        xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        + "\n".join(urls) + "\n</urlset>\n"
    )


def robots() -> str:
    return (
        "User-agent: *\n"
        "Allow: /\n"
        f"Sitemap: {SITE_URL}sitemap.xml\n"
    )


def outputs() -> dict[Path, str]:
    files = {
        SITE / "index.html": render("en"),
        SITE / "zh" / "index.html": render("zh"),
        SITE / "ja" / "index.html": render("ja"),
        SITE / "zh-hant" / "index.html": render("zh-hant"),
        SITE / "sitemap.xml": sitemap(),
        SITE / "robots.txt": robots(),
        SITE / "llms.txt": f"""# TrueScale for QUADERNO

> TrueScale is a free, MIT-licensed, open-source macOS application for preparing PDFs for FUJITSU QUADERNO and sending them over USB or Wi-Fi.

TrueScale / TrueScale PDF / QUADERNO PDF 转换器 refer to this project. Repository slug: eink-truescale-pdf. It is independent of Fujitsu. This file describes the published product, not unreleased local builds.

## Authoritative links
- [Homepage]({SITE_URL})
- [简体中文官网]({SITE_URL}zh/)
- [繁體中文官網]({SITE_URL}zh-hant/)
- [日本語]({SITE_URL}ja/)
- [GitHub source]({REPO})
- [Downloads and released versions]({RELEASES})
- [Changelog]({CHANGELOG})
- [License]({REPO}/blob/master/LICENSE)

## Scope and limits
Apple Silicon Mac; macOS 14 or later. Text, Markdown and supported ebooks can be typeset at the actual device page size. Existing PDFs can be delivered without reflow. First-time pairing uses the official QUADERNO software. DRM removal is not supported. Check the release notes for features in the downloadable binary.

## 中文说明
TrueScale for QUADERNO 是免费的开源 Mac 应用：为富士通 QUADERNO 排版文字、Markdown 和 EPUB，并通过 USB 或 Wi-Fi 投递 PDF。仓库名为 eink-truescale-pdf，软件名为 TrueScale for QUADERNO；两者指向同一个项目。
""",
    }
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if generated files are stale")
    args = parser.parse_args()
    validate()
    files = outputs()
    validate_markup(files)
    stale = [str(p.relative_to(SITE.parent)) for p, text in files.items()
             if not p.exists() or p.read_text(encoding="utf-8") != text]
    if args.check:
        if stale:
            print("stale generated files: " + ", ".join(stale), file=sys.stderr)
            return 1
        print("site output is up to date")
        return 0
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print("wrote", path.relative_to(SITE.parent))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
