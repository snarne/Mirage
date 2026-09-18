#!/usr/bin/env bash
# Check that this Mac can drive this iPhone, one precondition at a time.
#
# Mirage.app does all of this itself and reports failures in its setup flow. This script
# exists for the case the app cannot answer: whether location simulation still works on a
# particular iOS version. Apple has moved the service before and may again, and a shell
# script that stops at the exact failing step is the fastest way to find out.
#
# Usage:  ./scripts/check-device.sh [lat] [lon]
set -uo pipefail

LAT="${1:-37.7749}"
LON="${2:--122.4194}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$*"; exit 1; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$*"; }
warn() { printf '\033[33mnote\033[0m  %s\n' "$*"; }

# --- locate the CLI -----------------------------------------------------------
# It lives in the project venv, not on PATH. Resolving it explicitly avoids
# reporting "no device" when the real problem is a missing binary.
if [[ -x "$ROOT/.venv/bin/pymobiledevice3" ]]; then
  PMD3="$ROOT/.venv/bin/pymobiledevice3"
elif command -v pymobiledevice3 >/dev/null 2>&1; then
  PMD3="$(command -v pymobiledevice3)"
else
  fail "pymobiledevice3 not found.
      Expected it at $ROOT/.venv/bin/pymobiledevice3

      Create the environment first:
        python3.14 -m venv '$ROOT/.venv'
        '$ROOT/.venv/bin/pip' install -U pymobiledevice3"
fi
ok "using $PMD3 ($("$PMD3" version 2>/dev/null | tail -1))"

# --- 1. device present --------------------------------------------------------
bold $'\n1. Paired devices'
DEVICES="$("$PMD3" usbmux list 2>&1)" || fail "usbmux list failed:
      $DEVICES"
if [[ -z "${DEVICES//[[:space:]]/}" || "$DEVICES" == "[]" ]]; then
  fail "No device known to usbmuxd.
      Connect the iPhone by USB, unlock it, and tap Trust."
fi
echo "$DEVICES" | head -20
UDID="$(echo "$DEVICES" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9a-f]{40}' | head -1)"
[[ -n "$UDID" ]] && ok "device ${UDID:0:6}...${UDID: -4}" || warn "could not parse a UDID; continuing"

# --- 2. developer mode --------------------------------------------------------
bold $'\n2. Developer Mode'
DM="$("$PMD3" amfi developer-mode-status 2>&1)"
if echo "$DM" | grep -qi "true"; then
  ok "enabled"
else
  echo "      $DM"
  fail "Developer Mode is off.
      On the iPhone: Settings > Privacy & Security > Developer Mode > On, then reboot.
      If the toggle is not there, run:  $PMD3 amfi reveal-developer-mode"
fi

# --- 3. developer disk image --------------------------------------------------
bold $'\n3. DeveloperDiskImage'
if MOUNT="$("$PMD3" mounter auto-mount 2>&1)"; then
  ok "mounted"
else
  if echo "$MOUNT" | grep -qi "already"; then ok "already mounted"; else
    echo "      $MOUNT"
    warn "auto-mount did not succeed; the DVT step below will show whether it matters"
  fi
fi

# --- 4. tunnel ----------------------------------------------------------------
# Mirage opens Apple's native remotepairingd tunnel in-process, which needs no root.
# pymobiledevice3's `tunneld` daemon does need root; it is not used here.
bold $'\n4. Tunnel'
if "$ROOT/.venv/bin/python" - <<'PYEOF' 2>/dev/null
import asyncio, sys
sys.path.insert(0, "core")
from mirage.device import connect
async def main():
    conn = await connect()
    print(f"      transport: {conn.transport}")
    await conn.aclose()
asyncio.run(main())
PYEOF
then
  ok "tunnel established without elevated privileges"
else
  warn "could not open a tunnel; the DVT step below will show the exact failure"
fi

# --- 5. the actual test -------------------------------------------------------
bold $'\n5. Inject location'
printf '      setting %s, %s\n' "$LAT" "$LON"
if OUT="$("$PMD3" developer dvt simulate-location set -- "$LAT" "$LON" 2>&1)"; then
  ok "DVT accepted the coordinate"
else
  echo "$OUT"
  fail "The device rejected the request. This is the answer this script exists to find:
      on this iOS version the location simulation service may have moved or been removed."
fi

cat <<BANNER

  ─────────────────────────────────────────────────────────────────────
  Now check, in order. Only the third one actually matters.

    1. Apple Maps on the iPhone         -> blue dot at the target?
    2. Weather app                      -> target city?
    3. FIND MY, FROM A SECOND APPLE ID  -> target city?   <-- THE TEST
  ─────────────────────────────────────────────────────────────────────

BANNER
read -r -p "  Press return to clear the simulated location and restore real GPS "
"$PMD3" developer dvt simulate-location clear >/dev/null 2>&1 \
  && ok "cleared — device is back on real GPS" \
  || warn "clear failed; run '$PMD3 developer dvt simulate-location clear' manually"
