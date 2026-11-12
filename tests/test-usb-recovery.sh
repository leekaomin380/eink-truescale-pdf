#!/bin/zsh
set -euo pipefail
REPO="${0:A:h:h}"
WORK=$(mktemp -d /tmp/p2q_usb.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
swiftc "$REPO/gui/mac/USBRecovery.swift" "$REPO/tests/USBRecoveryTests.swift" -o "$WORK/policy"
"$WORK/policy"
swiftc "$REPO/gui/mac/DirectDelivery.swift" "$REPO/gui/mac/ProcessRunner.swift" \
  "$REPO/tests/USBTransportTests.swift" -o "$WORK/transport"
"$WORK/transport"
