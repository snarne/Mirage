#!/usr/bin/env bash
#
# Build the Rust location bridge and put it where Swift can find it.
#
#     ./scripts/build-native.sh            # for this Mac, release
#     ./scripts/build-native.sh --debug    # faster to build, slower to run
#     ./scripts/build-native.sh --ios      # for the iPhone (arm64 device)
#
# The Mac build is what `swift build` and `swift test` in ui/ link against. The iPhone
# build is what ios/Mirage.xcodeproj links against; run it before opening the project, or
# Xcode will fail to link with "library not found for -lmirage_idevice".
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/native/mirage-idevice"
SHIM="$ROOT/ui/Sources/CMirageIdevice"

PROFILE="release"
CARGO_FLAGS=(--release)
TARGET=""

case "${1:-}" in
  --debug)
    PROFILE="debug"
    CARGO_FLAGS=()
    ;;
  --ios)
    TARGET="aarch64-apple-ios"
    CARGO_FLAGS=(--release --target "$TARGET")
    ;;
  "")
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  cat >&2 <<'EOF'
cargo not found.

The location bridge is Rust, because idevice is. Install the toolchain:

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

then run this script again.
EOF
  exit 1
fi

if [[ -n "$TARGET" ]]; then
  if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    echo "==> adding the $TARGET toolchain"
    rustup target add "$TARGET"
  fi
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode's command line tools are needed to link for iOS: xcode-select --install" >&2
    exit 1
  fi
fi

echo "==> building mirage-idevice (${TARGET:-host}, $PROFILE)"
if [[ -n "$TARGET" ]]; then
  # The library only. mirage-pair is a Mac tool — building it for the phone would be
  # meaningless, and it pulls in a stdin prompt that has nowhere to run there.
  cargo build --manifest-path "$CRATE/Cargo.toml" --lib "${CARGO_FLAGS[@]}"
else
  cargo build --manifest-path "$CRATE/Cargo.toml" "${CARGO_FLAGS[@]}"
fi

if [[ -n "$TARGET" ]]; then
  LIB="$CRATE/target/$TARGET/$PROFILE/libmirage_idevice.a"
else
  LIB="$CRATE/target/$PROFILE/libmirage_idevice.a"
fi

if [[ ! -f "$LIB" ]]; then
  echo "cargo reported success but $LIB is missing" >&2
  exit 1
fi

# The shim's header #includes the crate's rather than copying it, so there is nothing to
# refresh and nothing that can go stale. Only the module map is written here.
echo "==> refreshing $SHIM"
mkdir -p "$SHIM"

cat > "$SHIM/module.modulemap" <<'EOF'
module CMirageIdevice {
    header "mirage_idevice.h"
    link "mirage_idevice"
    export *
}
EOF

echo
echo "Built:  $LIB"
echo "Shim:   $SHIM"
if [[ -z "$TARGET" ]]; then
  echo "Tool:   $CRATE/target/$PROFILE/mirage-pair"
fi

if [[ -n "$TARGET" ]]; then
  cat <<'EOF'

Next:  ./scripts/gen-xcodeproj.sh && open ios/Mirage.xcodeproj
EOF
else
  cat <<'EOF'

Next:  cd ui && swift build
EOF
fi
