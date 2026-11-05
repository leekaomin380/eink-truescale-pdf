# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). No
version tags have been cut yet — everything below is `Unreleased`, seeded
retrospectively from the project's git history to give newcomers a map without
requiring them to read every commit.

## [Unreleased] — 2026-11-04/05 robustness hardening

### Fixed
- Concurrent deliveries now queue: a FIFO gate in the App serializes helper calls, and the
  cross-process lock waits for a full transaction instead of failing after 30 s.
- USB serial-mode probing and `tcdrain` moved off the main actor; the drain is bounded to
  2 s and a failed switch is retried with backoff instead of leaving an 80 s dead window.
- Empty PDFs are rejected; device file names are sanitized and bounded to 100 characters;
  byte-identical repeat uploads are skipped; a missing local tool is no longer reported
  as a device connection failure.
- The device file manager compensates for the firmware's 3–4 s directory index delay with
  bounded (0/3/6 s) refresh after changes.

### Verification
77 Python unit tests, 74 regression assertions, zero-warning build, strict codesign, and
on-device probes for empty input, long names, idempotency and concurrent delivery. All
probe entries and history records were removed; see `docs/audit/CFR-2026-11-04-robustness.md` §9.

## [1.2.2] — 2026-11-02

### Changed
- Finder right-click **Send to QUADERNO** no longer shows the app: it hands the foreground back
  to Finder, and when the app was not running it works without a window or Dock icon and quits
  when the delivery finishes.

### Added
- Finder right-click delivery for EPUB, typeset as a book with the ⌃1 / Finder layout.
- Built-in global hotkeys: ⌃1 sends the clipboard, ⌃2 saves a device screenshot. No setup in
  the Shortcuts app; change or turn them off in Settings → Hotkeys. Remove an old ⌃1 binding
  in the Shortcuts app, which would otherwise take the key first.
- Screenshots are named after the open document and page (e.g. `Reading notes p3 2026-11-02 14.05.12.png`)
  instead of only the time, and a copy also goes to the Desktop (Settings → Screenshot, on by default).
- The app stays in the menu bar when its window is closed, so hotkeys and automatic USB
  network switching keep working; optional Open at Login.

## [1.2.1] — 2026-11-01

### Changed
- New app icon: grayscale paper in the style of the author's ReadIsland app, with an
  italic lowercase q in the top-left corner. The previous icon used more than four
  colours. The landing page icon and favicon follow the same design.

## [1.2.0] — 2026-11-01

Renamed **Quaderno Converter → TrueScale for QUADERNO** (bundle ID
`io.github.leekaomin380.quaderno-converter`). Settings are migrated on first launch;
re-copy the ⌃1 Shortcut command once, because the app's path changed.

### Added
- Direct delivery to the device over USB / local network (HTTPS API, pinned key),
  saved to `Document/Received/`, opened on the device, read back and SHA-256-checked.
  No official client needed after a one-time pairing import.
- Fallback to QUADERNO PC App when the direct connection fails before upload and the
  official app is running.
- Finder right-click **Send to QUADERNO** (native macOS service) for PDF, Markdown, TXT.
- 简体中文 / English / 日本語 UI and messages, with a language setting.
- First-run setup guide (connect → import pairing → check → optional ⌃1).
- Settings and About pages in the main window; About lists bundled components and licences.
- Recent deliveries from every entry point (toolbar), with retry, reveal in Finder,
  open on device and locate in Device Files.
- Device Files: browse, search, sort, download (with handwriting), upload, move,
  create folders and delete (always confirmed).
- Screenshot export (⌘⇧S): saves the device screen, handwriting included, as PNG,
  JPEG or a true-size PDF into a folder chosen once.
- The device is switched from USB serial mode to network mode by TrueScale itself;
  QUADERNO PC App no longer needs to be running.
- Global USB / network status in the toolbar (ready / network not ready / disconnected).

### Fixed
- A title derived from the first line of the text was printed twice on the page.


### Added
- `deliver.sh` — clipboard Markdown → 1:1-scaled PDF → QUADERNO, via a global
  hotkey (macOS Shortcuts). Renders at the device's measured true physical
  display size, eliminating the device-side rescaling that causes most
  "e-ink looks blurry" complaints.
- `book.sh` — EPUB/FB2/HTML/Markdown → PDF, same 1:1 pipeline, with generated
  PDF outline (bookmarks), table of contents, per-chapter page breaks, and
  metadata carried over from the source ebook. MOBI/AZW via Calibre.
  `--plain` mode for pasted text (no TOC/chapter forcing).
- Native macOS GUI (`gui/Quaderno Converter.app`) — SwiftUI + PDFKit, no
  bundled interpreter. Drag-and-drop, paste-text, or WeChat-link input,
  live per-parameter readouts (measure width, CJK/Latin characters-per-line),
  whole-document preview with render-once-and-reuse (parameters unchanged →
  no re-render on save/deliver). The only network activity is fetching a
  WeChat article and its images when you paste a link — nothing else phones
  home, and there is no telemetry.
- **WeChat Official Account (微信公众号) article support** — paste an
  `mp.weixin.qq.com` link and get a correctly-sized PDF. Fills a real gap:
  QUADERNO is a Japanese device with no path for Chinese social-platform
  content, while 微信公众号 hosts a large share of Chinese long-form writing.
  Extraction runs entirely on-device: `URLSession` fetches the HTML, a
  `WKWebView` with *all* network requests blocked runs a DOM-based extractor
  against the page's own structure (`#js_content`), and images are downloaded
  separately, grayscaled, JPEG-compressed and inlined as `data:` URIs. Blocking
  the WebView's network is both a privacy measure (Tencent's CDN never learns
  which article you're reading) and a 6× speedup (measured 1343 ms → 225 ms).
  Ported from the author's ReadIsland project.
- `gui.sh` — lightweight web-based alternative to the native app (Python
  standard library HTTP server, no Xcode required).
- `calibrate.typ` — a printable calibration page that turns "what's my
  screen's true physical size" from a manufacturer-unpublished number into a
  five-minute ruler measurement. Verified against QUADERNO A5.
- `devices.json` — device parameter database keyed by *size class*
  (diagonal + aspect ratio), not by device or panel model — because physical
  display size is a geometric constant independent of resolution/ppi (see
  `docs/quaderno-display-metrics.md`). One measurement per size class covers
  every device that uses it, present or future.
- `docs/typography-for-eink.md` — traditional print typesetting norms adapted
  for e-ink's lower contrast and resolution; includes a corrected finding on
  stroke-contrast fonts (Songti/Ming-style serifs render fine at 227 ppi —
  an earlier draft's claim otherwise was wrong and the correction is kept in
  the doc rather than silently edited out).
- `test.sh` — 16 assertions covering the invariants in `docs/PRD.md` §7, each
  traceable to a real bug that shipped once (mixed page sizes across a
  document, delivery deleting the only copy of a file, Markdown dialect
  crashes on `@mentions`/`$variables`, EPUB internal-anchor crashes, and
  more).
- `docs/PRD.md` — written after a full round of technical exploration rather
  than at project start, specifically so it could encode verified facts
  instead of the assumptions a day-one PRD would have gotten wrong (e.g.
  "QUADERNO A4/A5" are model names, not paper sizes).

### Fixed
- Clipboard/pasted text containing `@mentions`, email addresses, or shell-like
  `$variables` no longer crashes rendering (Pandoc's `citations` and
  `tex_math_dollars` Markdown extensions were misinterpreting them).
- EPUBs with internal footnote anchors that don't resolve to a real target no
  longer abort the entire render (handled via `book-filter.lua`).
- A `book.sh --deliver` invocation whose output path happened to collide with
  its delivery-copy path could delete the only rendered copy of the document;
  fixed by using a distinct, private staging path.

### Changed
- Project renamed from `print-to-quaderno` to `eink-truescale` — the durable
  asset here is the true-physical-size rendering method and the calibration
  technique, which apply to any e-ink device; QUADERNO remains the one device
  with a working delivery integration, since that protocol was
  reverse-engineered and is device-specific.
