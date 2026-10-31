#!/bin/zsh
# Reproducible standalone runtime; no user's keys are bundled.
set -euo pipefail
DIR="${0:A:h}"
REPO="${DIR:A:h}"
BUILD="$REPO/.build/direct"
mkdir -p "$BUILD"
uv venv --python 3.13 "$BUILD/venv"
uv pip install --python "$BUILD/venv/bin/python" -r "$DIR/requirements-build.txt"
"$BUILD/venv/bin/pyinstaller" --noconfirm --onedir --name quaderno-direct \
  --distpath "$DIR/runtime-dist" --workpath "$BUILD/pyinstaller" --specpath "$BUILD" \
  --copy-metadata pycryptodome --copy-metadata pyyaml "$DIR/quaderno_direct.py"
