# print-to-quaderno

**Copy text → press a hotkey → it appears on your e-ink device.** No GUI, no windows, nothing steals your focus.

Turns whatever Markdown is on your clipboard into a properly typeset PDF and delivers it
straight into your Fujitsu QUADERNO's sync queue — entirely in the background.

```
Copy Markdown  ──►  ⌃⌥⌘P  ──►  it's on your e-ink screen
```

Built for people who read long-form text on e-ink and are tired of this dance:
*copy → open a note app → paste → Cmd+P → hunt for "Print to QUADERNO" in a dropdown.*

---

## Does this apply to you?

**Please read this before installing.** This tool is narrow on purpose, and it is better
that you find out in 30 seconds than after twenty minutes of setup.

You need **all** of the following:

- [ ] **macOS** (tested on Sequoia / Darwin 24)
- [ ] **A Fujitsu QUADERNO device** — A5 (FMVDP51) or A4 (FMVDP41)
- [ ] **QUADERNO PC App** installed, and your device paired and showing *Connected*
- [ ] **Homebrew**, to install two small dependencies

If you don't own a QUADERNO, this tool cannot help you — but
[the calibration method](docs/quaderno-display-metrics.md) probably can, and it works on
any e-ink device.

> **Currently tuned for the A5 model.** A4 owners: everything works, but you must change two
> values first — see [Adapting to the A4 model](#adapting-to-the-a4-model).

---

## Install

```bash
brew install pandoc typst
git clone https://github.com/leekaomin380/print-to-quaderno.git
cd print-to-quaderno
chmod +x deliver.sh
./deliver.sh --check     # verify every link in the chain
```

`--check` matters more than it looks. This tool has five independent moving parts and
**most of them fail silently** when broken. Run it first; run it again any time something
seems off.

There is deliberately **no `curl | sh` installer**. This script reads your clipboard and
calls system APIs — you should be able to read it before you run it.
It's short, and every non-obvious line is commented.

---

## Bind the hotkey

This is the one step that cannot be automated. Apple does not allow programs to create
Shortcuts or register global hotkeys on your behalf, so you have to click through it once.
It takes about a minute.

1. Open **Shortcuts.app** → click **+** to create a new shortcut
2. Search the action list for **Run Shell Script** and add it
3. Replace the contents of the script box with **the absolute path to `deliver.sh`**, and nothing else:
   ```
   /full/path/to/print-to-quaderno/deliver.sh
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
| `.epub` `.fb2` `.html` `.md` | Directly, via pandoc |
| `.mobi` `.azw` `.azw3` | Via Calibre (`brew install --cask calibre`), converted to EPUB first |

> DRM-protected files cannot be converted. That is not a limitation we can work around.

It's a separate script from `deliver.sh` on purpose: a clipboard snippet renders in half a
second and is thrown away, while a book takes far longer, needs chapters and a TOC, and
should be kept. Different lifecycles, different tools.

**Does your device show PDF bookmarks?** We generate them, but whether QUADERNO's reader
exposes an outline navigator is not yet confirmed. If you find out, please tell us.

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

Change two values in `deliver.sh`:

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
(typesetting). Neither is bundled; both are installed via Homebrew.

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
