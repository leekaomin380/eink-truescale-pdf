#!/bin/zsh
set -euo pipefail
REPO="${0:A:h:h}"
WORK=$(mktemp -d /tmp/p2q_preview.XXXXXX)
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
  "$REPO/gui/mac/ProcessRunner.swift" \
  "$REPO/gui/mac/Localization.swift" \
  "$REPO/gui/mac/ClipboardLayout.swift" \
  "$REPO/gui/mac/DirectDelivery.swift" \
  "$REPO/gui/mac/wechat/WeChatExtractor.swift" \
  "$REPO/gui/mac/wechat/LocalExtraction.swift" \
  "$REPO/gui/mac/wechat/ImageInliner.swift" \
  "$REPO/tests/PreviewFreshnessTests.swift" \
  -o "$WORK/tests" -framework AppKit -framework SwiftUI -framework PDFKit \
  -framework WebKit -framework CoreImage -target arm64-apple-macos14.0
"$WORK/tests" "$REPO" "${1:-$WORK/preview.pdf}"
