# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). No
version tags have been cut yet — everything below is `Unreleased`, seeded
retrospectively from the project's git history to give newcomers a map without
requiring them to read every commit.

## [Unreleased]

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
  network calls, no bundled interpreter. Drag-and-drop or paste-text input,
  live per-parameter readouts (measure width, CJK/Latin characters-per-line),
  whole-document preview with render-once-and-reuse (parameters unchanged →
  no re-render on save/deliver).
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
