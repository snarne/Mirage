#!/usr/bin/env bash
#
# Collect the two things the iPhone app needs from this Mac, once.
#
#     ./scripts/prepare-phone.sh
#
# Produces a folder on the Desktop holding:
#
#   pairing.plist      the RemotePairing credential the phone presents to itself. Only a
#                      computer the phone already trusts can mint one, which is exactly
#                      why setup needs a Mac once — and only once.
#
#   Image.dmg          Apple's developer disk image, plus its trust cache and build
#   *.trustcache       manifest, taken out of Xcode. The developer-tools channel Mirage
#   BuildManifest.plist drives only exists while one of these is mounted, and a mount is
#                      lost every time the phone restarts. Shipping them with Mirage would
#                      be redistributing Apple's software, so Mirage asks for yours and
#                      mounts it itself.
#
# AirDrop the folder to the iPhone, then import it in Mirage > Setup.
#
# Nothing here leaves your machine, and nothing is written into the repo — the output goes
# to the Desktop precisely so it cannot be committed by accident. Treat the folder like a
# key: a pairing file is enough to talk to your phone.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/Desktop/Mirage Setup}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This has to run on the Mac the iPhone is paired with."
fi

mkdir -p "$OUT"

# --- 1. the pairing file ------------------------------------------------------

bold "Pairing file"

# Not the lockdown pair record in /var/db/lockdown, which is what idevicepair and
# pymobiledevice3 deal in. The on-device path never touches lockdown: it talks to
# `remoted` over RemotePairing, which authenticates with an Ed25519 keypair in a file of
# its own. The two are not convertible, and the wrong one fails with nothing more useful
# than a socket error. mirage-pair does the real pairing, over USB, from here.
PAIR_TOOL="$ROOT/native/mirage-idevice/target/release/mirage-pair"
if [[ ! -x "$PAIR_TOOL" ]]; then
  echo "   building the pairing tool"
  "$ROOT/scripts/build-native.sh" >/dev/null || fail "could not build mirage-pair.
      Run ./scripts/build-native.sh on its own to see why."
fi

"$PAIR_TOOL" "$OUT/pairing.plist" || fail "could not pair with the iPhone.
      The reason is printed above."

chmod 600 "$OUT/pairing.plist"
ok "pairing.plist"

# --- 2. the developer disk image ---------------------------------------------

echo
bold "Developer disk image"

# Only the disk image step needs Python; the pairing is Rust now.
if [[ -x "$ROOT/.venv/bin/python" ]]; then
  PY="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
else
  fail "python3 not found. Run ./scripts/bootstrap.sh first."
fi

DEV="$(xcode-select -p 2>/dev/null || true)"
[[ -n "$DEV" ]] || fail "Xcode is not installed, or xcode-select points nowhere.
      The disk image ships with Xcode. Install it from the App Store, then:
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

# Xcode has moved this twice. Since Xcode 16 the iOS 17+ image is installed unpacked,
# outside the app bundle; before that it was a .dmg inside it that has to be attached.
# The DeviceSupport/*/DeveloperDiskImage.dmg files are the pre-iOS-17 kind and cannot be
# mounted this way at all, so they are deliberately not searched.
ROOT_DIR=""
ATTACHED=""

if [[ -f "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore/BuildManifest.plist" ]]; then
  ROOT_DIR="/Library/Developer/DeveloperDiskImages/iOS_DDI"
else
  DDI=""
  for candidate in \
    "$DEV/Platforms/iPhoneOS.platform/Library/Developer/CoreServices/iOS DDI.dmg" \
    "$DEV/Platforms/iPhoneOS.platform/Library/Developer/CoreServices/"*.dmg
  do
    [[ -f "$candidate" ]] && { DDI="$candidate"; break; }
  done

  [[ -n "$DDI" ]] || fail "no iOS 17+ developer disk image found.
      Looked in /Library/Developer/DeveloperDiskImages/iOS_DDI and inside Xcode.
      Open Xcode once and let it finish installing its platform support."

  echo "   attaching $DDI"
  ATTACHED="$(mktemp -d)"
  cleanup() { hdiutil detach "$ATTACHED" -quiet 2>/dev/null || true; rmdir "$ATTACHED" 2>/dev/null || true; }
  trap cleanup EXIT
  hdiutil attach "$DDI" -mountpoint "$ATTACHED" -nobrowse -readonly -quiet \
    || fail "could not open $DDI"
  ROOT_DIR="$ATTACHED"
fi

echo "   from $ROOT_DIR"

# Which of the files in there is the image and which is the trust cache is not something
# to guess from names — Xcode's are called things like 022-21793-062.dmg. The build
# manifest records the path of every component, so it is asked rather than second-guessed.
if ! "$PY" - "$ROOT_DIR" "$OUT" <<'PY_EOF'
import pathlib
import plistlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

manifests = list(root.rglob("BuildManifest.plist"))
if not manifests:
    sys.exit(f"No BuildManifest.plist under {root}. This is the pre-iOS-17 style of "
             f"image, which cannot be mounted from the phone.")

manifest_path = manifests[0]
base = manifest_path.parent
manifest = plistlib.loads(manifest_path.read_bytes())

identities = manifest.get("BuildIdentities") or []
if not identities:
    sys.exit(f"{manifest_path} lists no build identities.")

# Every identity names the same component paths; they differ only in the signing details,
# which are the device's business and not this script's.
components = identities[0].get("Manifest", {})

def component(name: str):
    entry = components.get(name) or {}
    path = (entry.get("Info") or {}).get("Path")
    if not path:
        return None
    candidate = base / path
    return candidate if candidate.exists() else None


# By name, not by extension. Xcode's folder holds more than one .dmg and more than one
# .trustcache — the cryptex bundle sits beside the image — and a trust cache paired with
# the wrong image fails on the phone with an error that explains none of this.
image = component("PersonalizedDMG")
trust_cache = component("LoadableTrustCache")

if image is not None and trust_cache is not None:
    stem = image.name
    if trust_cache.name != f"{stem}.trustcache":
        sys.exit(f"The manifest pairs {image.name} with {trust_cache.name}, which do not "
                 f"belong together. Refusing to send a mismatched pair.")
else:
    # Older manifests name these differently. Fall back to matching by filename, which is
    # safe only because the pairing is then checked explicitly.
    dmgs = {}
    caches = {}
    for name, entry in components.items():
        path = (entry.get("Info") or {}).get("Path")
        if not path:
            continue
        candidate = base / path
        if not candidate.exists():
            continue
        if path.endswith(".trustcache"):
            caches[pathlib.Path(path).name] = candidate
        elif path.endswith(".dmg"):
            dmgs[pathlib.Path(path).name] = candidate

    for name, candidate in dmgs.items():
        match = caches.get(f"{name}.trustcache")
        if match is not None:
            image, trust_cache = candidate, match
            break

if image is None or trust_cache is None:
    listed = ", ".join(sorted(components)) or "nothing"
    sys.exit(f"{manifest_path} does not point at an image and its matching trust cache "
             f"(it lists {listed}).")

out.mkdir(parents=True, exist_ok=True)


def place(source: pathlib.Path, name: str) -> None:
    """Copy contents only, and set the mode here.

    `copy2` would carry the source's permissions across, and these live under /Library
    owned by root at mode 0444 — so the copy lands read-only and the *next* run cannot
    overwrite it. Which is a strange way to find out that a script is not re-runnable.
    """
    destination = out / name
    destination.unlink(missing_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o600)


place(image, "Image.dmg")
place(trust_cache, "Image.dmg.trustcache")
place(manifest_path, "BuildManifest.plist")

# ProductVersion on a disk image is the image's own version, not iOS's, so printing it
# as "iOS 1.0" would be actively misleading. The build id is the useful identifier.
build = manifest.get("ProductBuildVersion") or "?"
print(f"   build {build} — {image.name} with {trust_cache.name}")
PY_EOF
then
  fail "could not extract the developer disk image.
      The reason is printed above."
fi

if [[ -n "$ATTACHED" ]]; then
  cleanup
  trap - EXIT
fi

ok "Image.dmg, Image.dmg.trustcache, BuildManifest.plist"

# --- done ---------------------------------------------------------------------

echo
bold "Ready"
cat <<EOF

  $OUT

  1. AirDrop that folder to the iPhone. Files will offer to uncompress it; do that.
  2. Open Mirage on the phone, go to Setup, and choose the folder.

  After this the Mac is not needed again until the pairing file expires, which takes
  weeks. Mirage re-mounts the disk image itself after every restart.

  Delete the folder from the Mac once the phone has it. A pairing file is a credential.

EOF
