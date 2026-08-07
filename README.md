# eink-truescale-pdf

**Copy text → press a hotkey → it appears on your e-ink device.** No GUI, no windows, nothing steals your focus.

The core finding here: most "PDF looks blurry on e-ink" complaints trace back to the
device silently rescaling a page sized for paper (A4/Letter) down to its actual screen —
losing sharpness in the process. Render at the screen's true physical size instead, and
227 ppi looks as clean as commercial e-readers. The delivery integration below targets
Fujitsu QUADERNO specifically (the reverse-engineered protocol is device-specific), but
the calibration method and typography findings apply to any e-ink device — see
[E-Ink Display Metrics](docs/quaderno-display-metrics.md).

Turns whatever Markdown is on your clipboard into a properly typeset PDF and delivers it
straight into your Fujitsu QUADERNO's sync queue — entirely in the background.

```
Copy Markdown  ──►  ⌃⌥⌘P  ──►  it's on your e-ink screen
```

Built for people who read long-form text on e-ink and are tired of this dance:
*copy → open a note app → paste → Cmd+P → hunt for "Print to QUADERNO" in a dropdown.*

> **📄 [Download the calibration page](https://github.com/leekaomin380/eink-truescale-pdf/releases/latest)** —
> works on *any* e-ink device, not just QUADERNO. Send it to your reader, hold a ruler
> against the screen, and find out whether it displays PDFs at true 1:1. No installation
> needed to use it.

**Four ways to get content onto the device**, all rendering at the screen's true
physical size:

| Source | How |
|---|---|
| Clipboard Markdown | Global hotkey — [jump](#bind-the-hotkey) |
| EPUB / MOBI ebooks | `book.sh` or the app — [jump](#converting-ebooks) |
| **WeChat articles (微信公众号)** | Paste a link into the app — [jump](#reading-wechat-articles-微信公众号-on-a-quaderno) |
| Pasted text | Type or paste into the app |

The WeChat support exists because QUADERNO is a Japanese device with no path for Chinese
social-platform content, and 微信公众号 is where much of Chinese long-form writing lives.
Extraction runs locally on your Mac — no server, no account.

---

## Does this apply to you?

**Please read this before installing.** This tool is narrow on purpose, and it is better
that you find out in 30 seconds than after twenty minutes of setup.

To use **everything**, including one-key delivery to the device:

- [ ] **Apple Silicon Mac** (M1 or newer), running macOS 14 or later
- [ ] **A Fujitsu QUADERNO device** — A5 (FMVDP51) or A4 (FMVDP41)
- [ ] **QUADERNO PC App** installed in `/Applications`, with your device paired and
      showing *Connected*

The downloadable desktop app is self-contained: **Homebrew, pandoc, typst, Xcode and a
manually configured command path are not required.** Homebrew is needed only when using
the source/command-line workflow described below.

**Without a QUADERNO**, only the delivery step is unavailable — the delivery protocol was
reverse-engineered from that specific client. Everything upstream of it still works, and
you can save the PDF and transfer it however you normally would:

- Converting EPUBs and **WeChat articles** into clean, correctly-sized PDFs
- [The calibration method](docs/quaderno-display-metrics.md) — works on any e-ink device
  (reMarkable, BOOX, Kindle Scribe…) and is what makes the sizing correct in the first place
- [The e-ink typography research](docs/typography-for-eink.md)

> **Currently tuned for the A5 model.** A4 owners: everything works, but you must change two
> values first — see [Adapting to the A4 model](#adapting-to-the-a4-model).

---

## Install

### Desktop app (recommended)

1. Download `Quaderno-Converter-1.0.0-macOS-arm64.zip` from the
   [latest GitHub Release](https://github.com/leekaomin380/eink-truescale-pdf/releases/latest).
2. Open the ZIP and drag **Quaderno Converter.app** into `/Applications`.
3. Install the official **QUADERNO PC App** into `/Applications`, pair the device, and
   confirm that it shows *Connected*.
4. Open Quaderno Converter. No command path or Shortcut configuration is needed.

The release is signed with Developer ID and notarized by Apple. It supports Apple Silicon
only. EPUB, FB2, HTML, Markdown, pasted text and web links work without additional tools;
MOBI/AZW conversion remains optional and requires Calibre.

### Source / command-line workflow

```bash
brew install pandoc typst
git clone https://github.com/leekaomin380/eink-truescale-pdf.git
cd eink-truescale-pdf
chmod +x deliver.sh
./deliver.sh --check     # verify every link in the chain
```

`--check` matters more than it looks. This tool has five independent moving parts and
**most of them fail silently** when broken. Run it first; run it again any time something
seems off.

There is deliberately **no `curl | sh` installer**. The script reads your clipboard and
calls system APIs — you should be able to read it before you run it.
It's short, and every non-obvious line is commented.

---

## Bind the hotkey

This is the one step that cannot be automated **for the shell-script workflow**: macOS
does not let a program create a Shortcut or assign its key binding on your behalf, so you
have to click through it once. It takes about a minute.

To be precise about what is and isn't possible, since this is easy to get wrong: an app
*can* register a global hotkey without any accessibility permission — Carbon's
`RegisterEventHotKey` does exactly that (measured: registration succeeds while
`AXIsProcessTrusted()` returns false). What macOS does not allow is programmatically
authoring a *Shortcuts.app* shortcut and binding a key to it. The two are different
mechanisms, and only the latter is closed off.

So this manual step exists because the CLI workflow routes through Shortcuts.app.
Building the hotkey into the app was considered and **deliberately dropped** — see
[TODO.md](TODO.md) for the reasoning. If you want a hotkey, bind one here; if you'd
rather not, the desktop app covers the same ground without one.

1. Open **Shortcuts.app** → click **+** to create a new shortcut
2. Search the action list for **Run Shell Script** and add it
3. Replace the contents of the script box with **the absolute path to `deliver.sh`**, and nothing else:
   ```
   /full/path/to/eink-truescale-pdf/deliver.sh
   ```
   Run `pwd` in the repo folder if you're not sure of the path.

   > Paste the **path**, not the script's contents. The script locates its template file
   > relative to its own location, which only works when it is invoked by path.

4. Confirm the settings:

   | Setting | Value |
   |---|---|
   | Shell | `zsh` |
   | Input | *(leave as default)* |
   | Pass input | *(leave as default)* |
   | Run as administrator | **unchecked** |

   The input settings genuinely don't matter — the script reads the clipboard itself via
   `pbpaste` and ignores stdin entirely.

5. Name it something like **Send to Quaderno**
6. Click **ⓘ** (Details) → **Add Keyboard Shortcut** → press your combination.
   `⌃⌥⌘P` is a good choice — almost nothing else uses it.
7. Close the window. Shortcuts saves automatically.

The first time you trigger it, macOS may ask for permission. Allow it once.

---

## Use it

1. Copy some Markdown
2. Press your hotkey
3. A notification confirms delivery; the document appears on your device shortly after

Your current window never loses focus. Nothing opens. Nothing flashes.

### What the notifications mean

| Notification | Meaning |
|---|---|
| ✅ Delivered · N chars | The client accepted the upload |
| ❌ Clipboard is empty | Nothing to send |
| ❌ Render failed: … | Markdown could not be typeset (reason included) |
| ❌ Device offline or cancelled | The client could not reach your device |
| ⚠️ Handed off but unconfirmed | Sent, but delivery could not be verified — check the device connection |

The failure notifications exist for a specific reason: **the QUADERNO client fails silently.**
If your device is offline it writes a line to a log file and tells you nothing. This script
watches that log so that a failed send cannot masquerade as a successful one.

---

## Converting ebooks

QUADERNO only accepts PDF, but most ebooks are EPUB. Converting them usually looks bad —
and now we know why: the output gets rendered at A4 or Letter, then squeezed onto a smaller
screen, shrinking the text and blurring every glyph. Same root cause as everything else here.

`book.sh` converts at the display's exact physical size instead:

```bash
./book.sh some-book.epub                 # writes some-book.pdf next to it
./book.sh some-book.epub --deliver       # convert and send to the device
./book.sh some-book.epub --lang en       # English book (affects TOC title, line breaking)
./book.sh some-book.epub -o out.pdf      # explicit output path
```

You get:

- **1:1 rendering** at the device's physical dimensions — no downscaling, no resampling
- **PDF outline (bookmarks)** generated automatically from the heading hierarchy
- **A table of contents page** with page numbers, up to three levels deep
- **Each chapter starts on a new page**
- **Title and author carried over** from the ebook's metadata

| Format | How |
|---|---|
| `.epub` `.fb2` `.html` `.htm` `.md` | Directly, via pandoc |
| `.mobi` `.azw` `.azw3` | Via Calibre (`brew install --cask calibre`), converted to EPUB first |

> DRM-protected files cannot be converted. That is not a limitation we can work around.

#### Local HTML conversion details

Local `.html` and `.htm` files are converted directly on your Mac (completely offline):

- **Typeset by document structure**: HTML is parsed into document nodes and typeset at the device's physical 1:1 size, rather than taking a screenshot of a browser window.
- **Local relative resources**: Images with relative paths (e.g., `<img src="images/cover.png">` or `article_files/image.png`) relative to the HTML file are resolved and embedded in the PDF.
- **No JavaScript execution**: Local HTML files are parsed statically. `<script>` tags are not executed.
- **Complex CSS & dynamic pages**: Pages relying on JavaScript or complex web CSS are re-typeset based on structural elements (headings, paragraphs, lists, tables, formulas); exact pixel-level browser layout is not guaranteed.
- **Conversion is strictly local**: No files, HTML, or resources are uploaded.

It's a separate script from `deliver.sh` on purpose: a clipboard snippet renders in half a
second and is thrown away, while a book takes far longer, needs chapters and a TOC, and
should be kept. Different lifecycles, different tools.

**Does your device show PDF bookmarks?** We generate them, but whether QUADERNO's reader
exposes an outline navigator is not yet confirmed. If you find out, please tell us.

---

## Reading WeChat articles (微信公众号) on a QUADERNO

QUADERNO is a Japanese device with no path for WeChat content — and WeChat's Official
Accounts platform (微信公众号) is where a large share of Chinese long-form writing
actually lives. This tool closes that gap **entirely on your Mac**: no server, no
account, no upload.

Paste an article URL into the app, and it extracts the text, inlines the images, and
renders it at your screen's true physical size — same pipeline as everything else here.

**In the app:** switch to **公众号链接 / WeChat link** → paste an
`https://mp.weixin.qq.com/s/...` URL → **解析并预览** → save the PDF or send it to
the device.

### How it works, and why it's built this way

```
URLSession fetches the HTML   ← the only network call you initiate
        ↓
WKWebView runs the extractor  ← all network BLOCKED inside this view
        ↓
Images downloaded separately  ← grayscaled + JPEG-compressed, inlined as data: URIs
        ↓
Markdown → book.sh → 1:1 PDF
```

The WebView blocks every request while parsing the page. That's deliberate: it keeps
Tencent's CDN from learning which article you're reading, and it makes extraction
roughly 6× faster (measured: 1343 ms → 225 ms — most of that time was spent waiting on
images the extractor never needed).

A few details that matter, all verified against real articles rather than assumed:

- **WeChat lazy-loads images.** The real URL lives in `data-src`; `src` is usually
  empty. In one measured article, 14 `<img>` tags broke down as 3 with a usable `src`,
  4 with `data-src`, and 7 bare placeholders. Reading only `src` loses most of the
  content images.
- **Images are grayscaled and re-encoded at JPEG q50** — but only kept if the result is
  actually smaller than the original, which for already-compressed WeChat JPEGs it often
  isn't. E-ink panels render 16 grey levels; the discarded bits don't physically exist
  on the target device.
- **Extraction runs on the page's own structure** (`#js_content`), not a generic
  readability heuristic. WeChat marks subheadings as bold paragraphs rather than `<h2>`,
  which generic extractors silently drop.

### When it doesn't work

| Message | Meaning |
|---|---|
| 微信要求验证 | WeChat is rate-limiting or challenging the request. Open the article once in WeChat, then retry. |
| 该文章已被删除或无法查看 | The article was removed by its publisher, or is otherwise unavailable. |
| 未能识别正文结构 | The page isn't an article (an account profile page, a video page, etc.). |

Only `mp.weixin.qq.com` links are accepted. General-purpose web article extraction is a
much harder problem and deliberately out of scope.

> The extraction core is ported from [ReadIsland](https://github.com/leekaomin380), the
> author's other project, where it has been in real-world use.

---

## Configuration

Shared page geometry and typography live in `config.sh`, sourced by both scripts — the
measured display dimensions are this project's core asset and must not drift between them.

```zsh
# config.sh
FONTS=("Helvetica Neue" "PingFang SC")   # Latin first, then CJK fallback
PAGE_W="157.1mm"                         # QUADERNO A5 display area
PAGE_H="209.5mm"
PAGE_MARGIN="10mm"
BODY_SIZE="10pt"
LEADING="0.85em"
```

### Choosing a font size

Because pages are rendered at the display's exact physical size, the device shows them
**1:1 with no scaling** — so `10pt` here is a real, physical 10pt on the glass, the same size
it would be on paper. (This is measured, not assumed; see below.)

That means you can simply look at a printed size menu and pick:

```bash
typst compile font-menu.typ menu.pdf
open -gj -na "/Applications/QUADERNO PC App.app" --args --print "$PWD/menu.pdf"
```

Sizes 8–14pt, each with its characters-per-line count. Whatever looks right on your screen
*is* what you'll get. Put that number in `BODY_SIZE`.

### Adapting to the A4 model

Change two values in `config.sh`:

```zsh
PAGE_W="202.7mm"
PAGE_H="270.3mm"
```

> ⚠️ These A4 numbers are **derived, not yet measured.** If you own an A4, please
> [run the calibration](#verifying-11-display) and tell us — you'd be the first.

---

## Verifying 1:1 display

Rendering at the display's physical size only works if the device shows PDFs at exactly
100% with no letterboxing. Don't take our word for it — measure:

**[Download the calibration page](https://github.com/leekaomin380/eink-truescale-pdf/releases/latest)**
and transfer it to your device however you normally would. Or build it yourself:

```bash
typst compile calibrate.typ calibration.pdf
open -gj -na "/Applications/QUADERNO PC App.app" --args --print "$PWD/calibration.pdf"
```

Hold a real ruler against the screen and measure the line marked **100 mm**.

| Result | Meaning | Fix |
|---|---|---|
| Exactly 100 mm | True 1:1 | Nothing to do |
| L mm | Scaled | Multiply `PAGE_W`/`PAGE_H` by `100 / L` |
| Corner marks missing | Device crops the page | Needs separate compensation |
| Horizontal ≠ vertical | Aspect ratio is wrong | Re-check the resolution figures |

**Measured result for QUADERNO A5: exactly 100 mm.** Confirmed 1:1, no scaling, no cropping.

The full method — including how the physical millimetre dimensions were derived from
published pixel counts — is written up in
**[E-Ink Display Metrics](docs/quaderno-display-metrics.md)**. It applies to any e-ink
device, not just QUADERNO.

---

## Troubleshooting

The script exits with a distinct code for each failure mode, so you can tell what happened
without guessing.

| Exit code | Cause | What to do |
|---|---|---|
| `1` | Clipboard empty | Copy something first |
| `2` | Render failed | Read `/tmp/quaderno_render_<PID>.log` — it has pandoc's actual error |
| `4` | Device offline or upload cancelled | Open the client, confirm it says *Connected* |
| `10` | Missing dependency | Run `./deliver.sh --check` |

### Known pitfalls (all already handled — documented so you recognise them)

These were all found the hard way. The script defends against each one, but if you fork or
modify it, these are the traps:

- **Garbled CJK text.** Shortcuts runs scripts with no locale set, so pandoc decides the
  input isn't UTF-8 and falls back to latin1. The script forces `LANG`/`LC_ALL`.
- **"pandoc not found"** even though it's installed. Shortcuts provides a minimal `PATH`
  without Homebrew. The script prepends `/opt/homebrew/bin`.
- **Text containing `@` crashes the render.** Pandoc's Markdown reader treats `@something`
  as a citation; with no bibliography, typst aborts. The script disables that extension —
  along with `$…$` math, which would otherwise eat shell variables like `$PATH` in your text.
- **Text looks small or blurry.** Almost always a page-size mismatch causing the device to
  downscale. See [Verifying 1:1 display](#verifying-11-display).

---

## How it works

```
pbpaste ──► [empty check] ──► pandoc ──► typst ──► PDF in /tmp
                                                      │
                                    open -gj -na QUADERNO --args --print
                                                      │
                        client uploads to device, then deletes the source file
                                                      │
                              [watch log + watch file] ──► notification
```

A few notes on why it's built this way:

- **The delivery protocol** (`open -na … --args --print`) was recovered by unpacking
  `/Library/PDF Services/Print to QUADERNO.workflow`. It's the client's own headless entry
  point, which lets us skip the macOS print subsystem entirely.
- **`-n` is mandatory.** macOS won't pass `--args` to an already-running application. This
  was tested; without `-n` nothing is delivered.
- **`-g -j`** keep the app backgrounded and hidden so your focus is never stolen.
- **Success is inferred** from the client consuming (deleting) the source file with no new
  errors in its log. The client provides no success signal of its own.
- **`/tmp` is mandatory** for rendering — pandoc tries to create temp directories in the
  read-only root otherwise, and crashes on Markdown containing images.

---

## The desktop app

A native macOS app, if you'd rather not use the terminal.

**The bundle is self-contained: pandoc and typst ship inside it**, so once built it runs
on a Mac with no Homebrew and no command-line tools at all — install the QUADERNO client
and it converts and sends, nothing else to set up. That costs about 306 MB (pandoc alone
is 263 MB and cannot be stripped further); making "just works" actually true was judged
worth the size.

The prebuilt app is available from the
[latest GitHub Release](https://github.com/leekaomin380/eink-truescale-pdf/releases/latest).
It is Developer ID signed and Apple-notarized for normal double-click installation.

**Apple Silicon only.** The bundled engines are arm64. On an Intel Mac, build it yourself
and the build packs your machine's own architecture.

To build:

```bash
brew install pandoc typst      # only needed on the build machine
./gui/build-app.sh             # builds gui/Quaderno Converter.app
```

Then double-click it in Finder. (To keep it around, drag it to `/Applications`.)

The GUI does **not** need a Shortcut or an absolute script path. The manual hotkey setup
above applies only to the separate command-line clipboard workflow.

Three input modes: **ebook conversion**, **pasted Markdown**, and
**WeChat article links** ([details above](#reading-wechat-articles-微信公众号-on-a-quaderno)).
Adjust fonts, size, margins and leading, preview any page, then save the PDF or send it
straight to the device.

Pure native SwiftUI (PDFKit for preview) — no Python server, no browser engine.
It shells out to the same `book.sh` / `deliver.sh` used by the CLI, so behavior
stays identical across all entry points.

### Lightweight alternative (no Xcode required)

If you don't have Xcode and don't want to build the native app,
`./gui.sh` starts the same GUI as a local web page (Python standard library
HTTP server, no third-party dependencies). Same features, same underlying
`book.sh`/`deliver.sh` — just rendered in a browser tab instead of a native
window. This path is kept intentionally minimal and is not the primary target
for new GUI features; the native app is where GUI development happens first.

---

## Contributing

**Device measurements are the most valuable thing you can contribute.**

The physical display dimensions of e-ink devices are not published by manufacturers — only
pixel counts and diagonal inches. We derive the millimetres and verify them with a ruler.
Right now this database has exactly one verified entry.

If you own **any** e-ink device — QUADERNO A4, reMarkable, BOOX, Kindle Scribe, anything —
the calibration page works on all of them, and measuring takes about five minutes.

Send us:

- The exact model name and SKU
- What you measured, in millimetres
- A photo of the ruler against the screen

Open a pull request, or just email it. Contributors are credited.

Code contributions are welcome too, especially A4 support and English error messages.

---

## Contact

- **Email** — leekaomin@foxmail.com
- **WeChat** — leekaomin
- **Issues** — bug reports and questions are welcome on GitHub

---

## Credits and licence

Built with [pandoc](https://pandoc.org) (syntax tree) and [typst](https://typst.app)
(typesetting). **Both are bundled inside the macOS app** so it runs without Homebrew;
the CLI scripts use whichever is on your `PATH`. pandoc is GPL-2.0-or-later and libgmp is
LGPL-3/GPL-2 — distributing those binaries carries obligations, which are documented and
discharged in **[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)** (component versions,
the exact binary modifications made, and where to get corresponding source). typst is
Apache-2.0. License texts ship inside the app under `Contents/Resources/licenses/`.

Not affiliated with or endorsed by Fujitsu. QUADERNO is their trademark.

Released under the [MIT License](LICENSE) — do what you like with it.

The device measurement data is released under **CC0**: public domain, no attribution
required. We would rather it spread than be credited.

---

## Also in this repository

| Document | |
|---|---|
| [E-Ink Display Metrics](docs/quaderno-display-metrics.md) | How to derive and verify any e-ink device's physical display size |
| [Development log (中文)](docs/development-log-zh.md) | The full investigation, every dead end and fix |
| [`calibrate.typ`](calibrate.typ) | 1:1 calibration page source |
| [`font-menu.typ`](font-menu.typ) | Font size menu source |
