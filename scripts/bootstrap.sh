#!/usr/bin/env bash
# One-time setup: create the Python environment the engine runs in.
# Mirage.app runs this for you; you only need it by hand for a headless install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/.venv"

find_python() {
  for c in python3.14 python3.13 python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then
      if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
        command -v "$c"; return 0
      fi
    fi
  done
  return 1
}

PY="$(find_python)" || {
  echo "Python 3.11 or newer is required."
  echo "  brew install python@3.14"
  exit 1
}
echo "==> Using $PY ($("$PY" --version))"

[[ -d "$VENV" ]] || { echo "==> Creating $VENV"; "$PY" -m venv "$VENV"; }

echo "==> Installing the engine"
"$VENV/bin/pip" install --quiet --upgrade pip
# [dev] pulls in the test dependencies too — a checkout you cannot run the tests from
# is not much of a checkout.
"$VENV/bin/pip" install --quiet -e "$ROOT/core[dev]"

echo "==> Verifying"
"$VENV/bin/python" -c "import mirage.cli, pymobiledevice3; print('   engine ok')"
echo
echo "Done. Launch Mirage.app, or run the engine directly:"
echo "    cd '$ROOT/core' && '$VENV/bin/python' -m mirage.cli --mock serve"
