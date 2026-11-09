#!/bin/zsh
set -euo pipefail
REPO="${0:A:h:h}"
WORK=$(mktemp -d /tmp/p2q_layout.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SDK_ARGS=()
if [[ ! -f "$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
  for sdk in MacOSX26.sdk MacOSX26.5.sdk MacOSX15.2.sdk; do
    if [[ -d "/Library/Developer/CommandLineTools/SDKs/$sdk" ]]; then
      SDK_ARGS=(-sdk "/Library/Developer/CommandLineTools/SDKs/$sdk")
      break
    fi
  done
fi
SOURCES=("$REPO"/gui/mac/*.swift "$REPO"/gui/mac/wechat/*.swift)
SOURCES=("${(@)SOURCES:#*/QuadernoApp.swift}")
swiftc "${SDK_ARGS[@]}" "${SOURCES[@]}" "$REPO/tests/WindowLayoutTests.swift" \
  -o "$WORK/tests" -framework AppKit -framework SwiftUI -framework PDFKit \
  -framework WebKit -framework CoreImage -framework IOKit -framework Vision -target arm64-apple-macos14.0
"$WORK/tests" "$REPO" "${1:-$WORK/layouts}"
