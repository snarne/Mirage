#!/usr/bin/env bash
# Assemble Mirage.app from the SPM build. SwiftUI + MapKit need a real bundle with an
# Info.plist; a bare SPM executable will not run as a GUI app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
# Override for your own signing identity, e.g. BUNDLE_ID=com.example.mirage
BUNDLE_ID="${BUNDLE_ID:-org.mirage.app}"
APP="$ROOT/build/Mirage.app"

echo "==> Building Swift ($CONFIG)"
swift build --package-path "$ROOT/ui" -c "$CONFIG"
# The SPM target is MirageMac; the bundle's executable is Mirage. See ui/Package.swift.
BIN="$(swift build --package-path "$ROOT/ui" -c "$CONFIG" --show-bin-path)/MirageMac"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mirage"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mirage</string>
  <key>CFBundleDisplayName</key><string>Mirage</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Mirage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <!-- tunneld's status endpoint is plain HTTP on loopback. Without this, App Transport
       Security blocks the health check and the app reports the tunnel as down. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# Signing.
#
# Ad-hoc ("-") is enough for Gatekeeper to run the app locally, but it leaves
# TeamIdentifier unset, and Apple will not serve Apple Account age data to a binary with
# no team — so age verification falls back to self-attestation. Set SIGN_IDENTITY to a
# real identity to enable Apple's age-verification path:
#
#     security find-identity -v -p codesigning     # list what you have
#     SIGN_IDENTITY="Apple Development: You (TEAMID)" ./scripts/build_app.sh
#
# Errors are shown rather than swallowed: the first signing attempt often triggers a
# keychain prompt, and hiding it makes an ad-hoc fallback look like a silent success.
SIGN_IDENTITY="${SIGN_IDENTITY:-"-"}"
if codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"; then
  TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
    echo "    signed ad-hoc — no Team ID, so Apple age verification is unavailable"
  else
    echo "    signed with team $TEAM"
  fi
else
  echo "    signing FAILED — the app may not launch"
  exit 1
fi

echo "==> Built $APP"
