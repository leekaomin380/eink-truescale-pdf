# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Released
versions are listed below, newest first. Version 1.3.0 collects the locally
deployed hardening and clipboard work dated 2026-11-04 through 2026-11-07.

## [Unreleased]

### Added
- Day Mark-style motion tokens (120 ms micro feedback, critically damped expansion,
  faster exits) for preview content, guides, disclosure and status changes. The paper
  frame stays still, Reduce Motion uses short fades, and measured progress never interpolates.
- Margin/footer changes show a 2.5-second guide on the preview paper, labelled as a
  settings illustration; the overlay does not render or alter the PDF.
- Optional Traditional Chinese PDF output converts visible document text and titles locally
  through Pandoc's AST; original input, code, math and link targets are preserved.
- Manual delivery reports real curl upload percentage, readback byte counts and hash-read
  progress. Connection/typesetting/confirmation stages remain indeterminate, and the
  action stays locked until final verification or failure.
- Font controls use equal-width native pickers, concise display names and family-name
  tooltips. One mixed-script specimen resolves explicit Regular/Roman faces, using the
  selected Chinese font for CJK text and the Latin font for English and numbers.
- Five additional installed-font choices: Noto Sans CJK SC, LXGW Neo ZhiSong,
  Kaiti SC, STFangsong and Baskerville. Chinese and Latin font pickers show live
  specimens with letters, digits and punctuation without starting PDF rendering.
- A4, A5, ISO B5, Letter and Legal PDF output with portrait/landscape orientation.
  Paper typography is saved separately from device typography; paper export never updates
  the shared clipboard-delivery profile. Standard paper prioritises PDF export.
- Consistent SF Symbols labels for layout settings and refresh/send/save actions.

### Fixed
- A quieter document workspace uses a continuous sidebar surface, lighter paper edges,
  unboxed status text and secondary refresh/Markdown actions. Only send or PDF save is
  prominent. The menu bar's lowercase q uses a smaller regular serif outline.
- The menu bar uses an 18-point lowercase serif q drawn from a vector font outline,
  preserving its counter and descender at small sizes with system-managed template tinting.
- Text previews now track title changes, preserve visible line breaks and recognise lists
  after a single newline. Edits during rendering queue a fresh render; send/save wait for
  the latest input. Editing only marks the preview as stale; refresh, send or save explicitly
  starts typesetting. Unchanged previews are reused.
- The text editor and settings share a scrollable area above a fixed action footer, so short
  windows keep all actions reachable. Page controls wrap when narrow, and the main window
  enforces its 900 × 600 point minimum.
- Pasting into the Text tab now converts clipboard HTML or RTF to editable Markdown,
  preserving headings, emphasis, lists, links and tables before PDF rendering. Plain
  text and Markdown remain editable; selection replacement and undo use native text editing.

## Website — 2026-11-10

### Changed
- Improve localized search titles/descriptions and visible product labels. Clearly distinguish
  PDF transfer from text/EPUB typesetting, preserve reciprocal canonical/hreflang mappings,
  and separate WebPage metadata from the actual released App version/date.
- Add responsive WebP photo and icon variants with correctly matched high-priority preload;
  extend the deployment gate for metadata, structured data, sitemap and image integrity.
- Replace the homepage photograph with the user-selected Katya Wolf / Pexels reading
  scene (photo 8715935). Lift exposure and shadows with AI-assisted tonal retouching;
  retain the unchanged original, source attribution, Pexels license and exact edit prompt.
- Adapt portrait cropping and soft image edges for desktop and mobile, and remove the
  previous strong desaturation so natural skin tones remain visible.
- Publish the update and its dated changelog in Simplified Chinese, Traditional Chinese,
  English and Japanese. Add a content hash to the stylesheet URL so returning visitors
  receive the matching image layout rather than cached styles.
- This follows the 2026-11-09 website refresh: system typography, the existing app icon
  as a visual element, an independent Traditional Chinese page and a QUADERNO tribute.

This is a **website deployment**, not an App release. The downloadable App remains
**1.3.0**; the App changes listed under Unreleased still await a separately signed and
notarized release.

## [1.3.0] — 2026-11-07

### Fixed
- File names containing `·` (U+00B7 MIDDLE DOT) or a bare Latin-1 `0xB7` no longer make
  the device report "the file has been deleted". Remote names fold the Latin-1 punctuation
  range, CJK characters stay intact, and device responses that fail strict UTF-8 decoding
  fall back to a lossy decode instead of raising.
- A failing `open2` viewer control is isolated from the upload transaction, so it no
  longer triggers the compensating `DELETE` of a document that was delivered correctly.
- Failed deliveries keep their rendered PDF for Retry, and `history.jsonl` records the
  traceback in `detail` instead of losing the failure reason.
- Tabs inside fenced code blocks are no longer mistaken for TSV table data.
- `clean_title` folds tabs and newlines before stripping control characters, so adjacent
  clipboard cells no longer concatenate into a single word in the file name.

### Added
- Clipboard normalization for non-Markdown sources, converged at one point in
  `render_and_upload`: HTML tables, TSV blocks and GFM pipe tables are mapped to a
  structural intermediate representation; plain text passes through unchanged. The ⌃1
  hotkey writes a `public.html` sidecar when the pasteboard carries rich HTML. Formula
  delimiters (`\(`, `\[`, `\\(`, `\\[`) survive verbatim; `colspan` becomes empty cells;
  `rowspan` is reported as unmapped and the source is kept.
- A table layout policy (`table-layout.lua`): column widths follow cell content length
  (CJK counted double), explicit alignment is preserved, long tables paginate with a
  repeating header, and over-wide or unsplittable tables degrade to a definition list.
  No whole-table scaling, no cropping, no dropped rows.
- `deliver.typ` restores the existing grey hairline / bold-header table vocabulary, and
  `figure.where(kind: table)` is breakable so a long table is not merged into one page.
- 104 Python unit tests and 87 regression assertions, including byte-identical output
  for plain text and formulas before and after the change.

### Changed
- Delivery latency is reduced by overlapping device authentication with book typesetting
  in a single helper process, overlapping the local SHA-256 with the directory query,
  and removing the `layout` helper plus its `plutil` subprocess. The verification chain
  is untouched: SHA-256 read-back, directory confirmation, failure cleanup, TLS public-key
  pinning, bounded timeouts and the cross-entry lock all remain.

### Verification
30-row table paginates over 5 pages with the header repeated 5/5 times, rows 1–30 intact
and a uniform page size; four-column widths change from 25/25/25/25% to
11.66/16.44/40.52/31.38%. Plain-text and formula PDFs are byte-identical in the text
layer. On-device delivery was not re-run; the single-variable check is to resend the
original AI reply with ⌃1.

### Robustness hardening (2026-11-04/05)

#### Fixed
- Concurrent deliveries now queue: a FIFO gate in the App serializes helper calls, and the
  cross-process lock waits for a full transaction instead of failing after 30 s.
- USB serial-mode probing and `tcdrain` moved off the main actor; the drain is bounded to
  2 s and a failed switch is retried with backoff instead of leaving an 80 s dead window.
- Empty PDFs are rejected; device file names are sanitized and bounded to 100 characters;
  byte-identical repeat uploads are skipped; a missing local tool is no longer reported
  as a device connection failure.
- The device file manager compensates for the firmware's 3–4 s directory index delay with
  bounded (0/3/6 s) refresh after changes.
- A USB link left at `IOLinkStatus = 0` (ECM driver attached, no valid medium, no `en5`,
  no mDNS service) is now detected separately from a stuck link. `prepare_usb` performs a
  bounded observation before a software re-enumeration, and discovery reports a link fault
  instead of a misleading "device address unreachable" error.
- External CLI deliveries (`deliver.sh`, hotkeys, Finder) now trigger the device file list
  refresh via `history.jsonl` write fingerprints; no separate IPC channel is needed.
- Orphan cleanup records are timestamped, retried at most 10 times, archived after 30 days
  across device pins, and never silently truncated at the record limit.
- The curl stall check uses a 32 KiB/s effective floor (90 s window) instead of 1 B/s.

#### Verification
84 Python unit tests, 74 regression assertions, zero-warning build, strict codesign, and
on-device probes for empty input, long names, idempotency, concurrent delivery, 24 MiB and
128 MiB end-to-end SHA-256 round-trips, plus a non-destructive USB link-injection/recovery
observation. All probe entries and history records were removed; see
`docs/audit/CFR-2026-11-04-robustness.md` §9–§10.

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
