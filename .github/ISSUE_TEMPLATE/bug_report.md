---
name: Bug report
about: Something didn't work
title: ""
labels: bug
---

<!--
Most issues in this project trace back to one of a handful of environment
quirks (locale, PATH, device connection) that are already documented in
README's Troubleshooting section — worth a quick check there first. If it's
still not it, the two commands below usually tell us where things broke
faster than a back-and-forth would.
-->

**Entry point** (check one)
- [ ] `deliver.sh` (hotkey / clipboard)
- [ ] `book.sh` (CLI ebook conversion)
- [ ] Native app (`Quaderno Converter.app`)
- [ ] `gui.sh` (web fallback)

**Output of `./test.sh`**
```
paste here
```

**Output of `./deliver.sh --check`**
```
paste here
```

**macOS version**


**Exact command or steps you ran**


**Expected vs. actual**


**Exit code, if the script failed** (see README's Troubleshooting table)


**If rendering failed:** contents of `/tmp/quaderno_render_<PID>.log`, if it's still there
