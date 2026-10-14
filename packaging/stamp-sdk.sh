#!/bin/bash
# Stamps the real macOS SDK version into a built binary (every architecture
# slice), re-signs it ad-hoc, and fails if the stamp didn't take.
#
#   bash packaging/stamp-sdk.sh <binary> [<binary> …]
#
# Why: `swift build` under Xcode 27 records the deployment target as the SDK
# the binary was built against (sdk 13.0 instead of 27.0). macOS then treats
# the program as built for an old SDK and keeps it on older compatibility
# paths. On macOS 27 that made a SwiftUI canvas stutter in our sister app
# Osler — same binary, only the stamp changed: old stamp stutters, real stamp
# is smooth. Run this after `swift build` and before the final signing.
set -euo pipefail

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

for BIN in "$@"; do
  MIN_OS="$(vtool -show-build "$BIN" | awk '$1 == "minos" { print $2; exit }')"
  vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$BIN.stamped" "$BIN" 2>/dev/null
  mv "$BIN.stamped" "$BIN"
  chmod +x "$BIN"
  # vtool invalidates the signature; an unsigned arm64 binary won't launch.
  codesign --force --sign - --timestamp=none "$BIN"
  # Every slice must carry the real SDK.
  if vtool -show-build "$BIN" | awk '$1 == "sdk" { print $2 }' | grep -qv "^$SDK_VERSION\$"; then
    echo "✗ $BIN: linked-SDK stamp didn't take (expected $SDK_VERSION)." >&2
    vtool -show-build "$BIN" >&2
    exit 1
  fi
  echo "▸ $(basename "$BIN"): linked-SDK stamp macOS $SDK_VERSION (minimum $MIN_OS)"
done
