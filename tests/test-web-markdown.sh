#!/bin/zsh
# Runs the actual WKWebView extractor against an offline article fixture.
set -euo pipefail
REPO="${0:A:h:h}"
WORK=$(mktemp -d /tmp/p2q_web_md.XXXXXX)
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
swiftc "${SDK_ARGS[@]}" \
  "$REPO/gui/mac/ConversionViewModel.swift" \
  "$REPO/gui/mac/wechat/WeChatExtractor.swift" \
  "$REPO/gui/mac/wechat/LocalExtraction.swift" \
  "$REPO/gui/mac/wechat/ImageInliner.swift" \
  "$REPO/tests/WebMarkdownTests.swift" \
  -o "$WORK/tests" -framework AppKit -framework PDFKit \
  -framework UniformTypeIdentifiers -framework WebKit -framework CoreImage \
  -target arm64-apple-macos14.0
"$WORK/tests" "$REPO/gui/mac/wechat/wechat_extractor.js"
