#!/usr/bin/env bash
#
# Generate ios/Mirage.xcodeproj from ios/project.yml.
#
#     ./scripts/gen-xcodeproj.sh
#     BUNDLE_ID_PREFIX=com.example.mirage DEVELOPMENT_TEAM=ABCDE12345 ./scripts/gen-xcodeproj.sh
#
# The project is generated, not committed: it is a pile of UUIDs that conflicts on every
# merge, and every person who builds this app signs it with their own identity anyway.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-app.mirage}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

# A Team ID is exactly ten alphanumerics. Anything else is a placeholder someone copied
# out of a README, and writing it into the project produces a signing failure that says
# nothing about where it came from.
if [[ -n "$DEVELOPMENT_TEAM" && ! "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  cat >&2 <<EOF
DEVELOPMENT_TEAM is "$DEVELOPMENT_TEAM", which is not a Team ID.

A Team ID is ten characters, like A1B2C3D4E5. Find yours in Xcode:
  Settings > Accounts > your Apple ID > the Team ID column.

Or leave it unset and pick the account in Xcode's Signing & Capabilities tab instead.
EOF
  exit 2
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> installing xcodegen"
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    cat >&2 <<'EOF'
xcodegen not found, and neither is Homebrew.

    brew install xcodegen

or grab a release from https://github.com/yonaskolb/XcodeGen/releases and put it on PATH.
EOF
    exit 1
  fi
fi

LIB="$ROOT/native/mirage-idevice/target/aarch64-apple-ios/release/libmirage_idevice.a"
if [[ ! -f "$LIB" ]]; then
  echo "==> the Rust bridge has not been built for iOS yet"
  "$ROOT/scripts/build-native.sh" --ios
fi

echo "==> generating ios/Mirage.xcodeproj  (prefix $BUNDLE_ID_PREFIX)"
cd "$ROOT/ios"
xcodegen generate --quiet

cat <<EOF

Done.  open ios/Mirage.xcodeproj

In Xcode, once:
  1. Select the Mirage target > Signing & Capabilities > your Apple ID.
     A free Apple ID is enough. It signs for seven days at a time.
  2. Do the same for the MirageWidgets target.
  3. If the bundle identifier is taken, re-run this with
       BUNDLE_ID_PREFIX=com.yourname.mirage ./scripts/gen-xcodeproj.sh

Then build to the phone, and run ./scripts/prepare-phone.sh to get it what it needs.
EOF
