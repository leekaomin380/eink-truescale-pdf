#!/bin/zsh
# Reproducible standalone runtime; no user's keys are bundled.
# gui/build-app.sh calls this itself whenever the sources no longer match the stamp below.
set -euo pipefail
DIR="${0:A:h}"
REPO="${DIR:A:h}"
source "$DIR/source-stamp.sh"
BUILD="$REPO/.build/direct"
mkdir -p "$BUILD"
[[ -x "$BUILD/venv/bin/python" ]] || uv venv --python 3.13 "$BUILD/venv"
uv pip install --python "$BUILD/venv/bin/python" -r "$DIR/requirements-build.txt"
"$BUILD/venv/bin/pyinstaller" --noconfirm --onedir --name quaderno-direct \
  --distpath "$DIR/runtime-dist" --workpath "$BUILD/pyinstaller" --specpath "$BUILD" \
  --copy-metadata pycryptodome --copy-metadata pyyaml "$DIR/quaderno_direct.py"
# Records which sources this runtime was built from; build-app.sh refuses a mismatch.
STAMP=$(direct_source_stamp "$DIR")
print -r -- "$STAMP" > "$DIR/runtime-dist/quaderno-direct/.source-stamp"
