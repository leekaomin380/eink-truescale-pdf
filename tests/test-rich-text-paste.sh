#!/bin/zsh
set -euo pipefail
REPO="${0:A:h:h}"
WORK=$(mktemp -d /tmp/p2q_rich_paste.XXXXXX)
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
swiftc "${SDK_ARGS[@]}" "$REPO/gui/mac/MarkdownPasteEditor.swift" \
  "$REPO/gui/mac/ProcessRunner.swift" "$REPO/tests/RichTextPasteTests.swift" \
  -o "$WORK/tests" -framework AppKit -framework SwiftUI -target arm64-apple-macos14.0
"$WORK/tests"
