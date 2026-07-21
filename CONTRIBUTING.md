# Contributing

There are two very different ways to contribute here, and the second one is more
valuable than the first.

## Device measurements (start here)

If you own any e-ink device, see the [Contributing section in
README](README.md#contributing) — measuring your device's true display size takes
about five minutes with the calibration page and is the single most useful thing
you can send. This section is about code.

## Code contributions

### Before you start

- Read [`docs/PRD.md`](docs/PRD.md) §7 ("Quality invariants") — every one of those
  eight rules was learned from a real bug that shipped once. They're not style
  preferences; violating one will very likely reintroduce a bug that's already been
  fixed once.
- `tasks/T-001.md` through `T-004.md` are dated task briefs written for a
  specific point in this project's history — not a template you need to follow.
  They're kept as a record of *why* a given piece of the system looks the way it
  does. Worth skimming if you're about to touch the GUI or `book.sh`.

### Setup

```bash
brew install pandoc typst poppler
./deliver.sh --check   # confirms the render pipeline works end to end
```

The native macOS app additionally needs Xcode (for `swiftc`); the `gui.sh` web
fallback needs nothing beyond the above.

### Before opening a PR

```bash
./test.sh
```

Sixteen assertions, a few seconds. If you touched `book.sh`, `deliver.typ`,
`config.sh`, or any font/rendering logic, run it — page-size and Markdown-dialect
regressions here are easy to introduce and easy to catch. If it can't run in your
environment (missing `pandoc`/`typst`), say so in the PR rather than skipping it
silently.

### Style

- Keep changes scoped to what the PR is about. Don't refactor adjacent code in the
  same PR, even if it's tempting.
- Comments only where they explain a non-obvious constraint or a "why," not what
  the code does. Most of this codebase has none, on purpose.
- Shell scripts target `zsh` (macOS default). Don't introduce bashisms.

### What's especially welcome

- **A4 device support** — the page geometry in `config.sh` is a derived value,
  never measured (see `docs/PRD.md` §9, assumption A1). If you own a QUADERNO A4,
  running the calibration and confirming or correcting that number would resolve
  the single largest open unknown in this project.
- English-language error messages (currently Chinese in some paths).
- Support for other e-ink devices' delivery protocols, if you can reverse-engineer
  one the way `deliver.sh`'s was found (see `docs/development-log-zh.md` for how
  QUADERNO's was recovered from its PDF Services workflow).

### What to avoid

- New third-party dependencies. The project's stated design goal is that a user
  should be able to read the entire delivery pipeline before running it; adding
  a pip package or npm dependency works against that.
- Anything that reduces to "make this more general" without a concrete second use
  case in front of you. See `docs/PRD.md` §8 for what's explicitly out of scope
  and why (Mac App Store distribution, `curl | sh` installers, UI automation).
