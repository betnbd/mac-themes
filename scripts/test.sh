#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
BUILD="$HOME/Library/Caches/MacThemes/Build"
SWIFT_BIN="$(xcrun --find swiftc)"
PLUGIN="${SWIFT_BIN:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
EXTRA=()
# Some beta Command Line Tools ship this plugin without registering it with SwiftPM.
if [[ -f "$PLUGIN" ]]; then EXTRA=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN"); fi
FRAMEWORKS="${SWIFT_BIN:h:h:h}/Library/Developer/Frameworks"
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  EXTRA+=(-Xlinker -rpath -Xlinker "$FRAMEWORKS")
  EXTRA+=(-Xlinker -rpath -Xlinker "${FRAMEWORKS:h}/usr/lib")
fi
swift test --scratch-path "$BUILD" "${EXTRA[@]}"
