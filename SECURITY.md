# Security

## What this software touches

`deliver.sh`, `book.sh`, and the GUI apps read your system clipboard and/or a file
you point them at, shell out to `pandoc`/`typst` (and `open` on macOS to hand a PDF
to the QUADERNO client), and write temporary files under `/tmp`. There is no
telemetry, no credential handling, and no third-party dependency beyond what
Homebrew installs (`pandoc`, `typst`, optionally `poppler`/`calibre`).

**The one network path** is the WeChat article feature: when *you* paste an
`mp.weixin.qq.com` link, the app fetches that page and the images it references.
Nothing is uploaded, no account is involved, and nothing is contacted unless you
paste a link. While parsing, the `WKWebView` doing the extraction has *every*
network request blocked via `WKContentRuleList` — so the page's own scripts and
trackers cannot fire, and Tencent's CDN is only contacted by our own deliberate
image fetches.

This is by design: the project's own stated principle is that **readability is the
trust mechanism**. There's deliberately no one-line `curl | sh` installer — you're
expected to be able to read `deliver.sh` (under 250 lines, plainly commented at the
non-obvious parts) before running it. If you can't finish that read in a few
minutes and feel confident about what it does, that's a documentation bug — please
report it.

## Reporting a vulnerability

Email **leekaomin@foxmail.com**. Please don't open a public issue for anything
that could be actively exploited before a fix ships — for a project this size a
private email is faster to act on anyway.

Include what you found, and a minimal reproduction if you have one. There's no
bug bounty; there is a genuine, prompt fix and credit in the commit message if you
want it.

## Scope

This is a personal-scale, single-maintainer project run on trust and code review,
not a hardened service. If your threat model requires supply-chain attestation,
signed releases, or a formal disclosure SLA, this project doesn't currently offer
that — happy to discuss what's realistic if it matters to your use case.
