"""Local trust boundary.

Mirage's control channel can move the user's apparent position anywhere on earth.
Anything that can reach it can do that too. The threat is not remote — it is every
other unsandboxed process running as this user, which on macOS includes any app the
user has ever double-clicked.

Three rules:

1. **Unix domain socket, never TCP.** A localhost TCP port is reachable by any process,
   and by web content via DNS rebinding. A socket file under a 0700 directory is
   reachable only by this uid, and is enforced by the kernel rather than by us.
2. **Verify the peer.** `LOCAL_PEERCRED` gives the connecting process's effective uid
   straight from the kernel — unspoofable. We refuse anything that is not us.
3. **Never handle iCloud credentials.** Mirage operates entirely at the device level
   over a trusted USB pairing. It has no reason to ask for an Apple ID, and asking
   would create a phishing-shaped surface for zero functional gain. There is no code
   path in this project that accepts one, and there should never be.
"""
from __future__ import annotations

import os
import socket
import struct
import sys
from pathlib import Path

# <sys/un.h> / <sys/socket.h> on Darwin
SOL_LOCAL = 0
LOCAL_PEERCRED = 0x001
XUCRED_VERSION = 0
SALT_FILE = "device-salt"


class PeerRejected(Exception):
    """The process on the other end of the socket is not allowed to talk to us."""


def state_dir() -> Path:
    """Owner-only directory for the socket and session state."""
    override = os.environ.get("MIRAGE_STATE_DIR")
    base = Path(override) if override else Path.home() / "Library" / "Application Support" / "Mirage"
    base.mkdir(parents=True, exist_ok=True)
    os.chmod(base, 0o700)
    return base


# sockaddr_un.sun_path is 104 bytes on Darwin, 108 on Linux, and the kernel does not
# truncate — it refuses the bind. A long username or a relocated home directory can
# push us over, so this is checked rather than assumed.
SUN_PATH_MAX = 104 if sys.platform == "darwin" else 108


def socket_path() -> Path:
    path = state_dir() / "control.sock"
    encoded = len(str(path).encode())
    if encoded >= SUN_PATH_MAX:
        raise RuntimeError(
            f"Control socket path is {encoded} bytes, over the {SUN_PATH_MAX}-byte "
            f"AF_UNIX limit: {path}. Set MIRAGE_STATE_DIR to something shorter."
        )
    return path


def harden_socket_file(path: Path) -> None:
    """Owner read/write only. Belt and braces over the 0700 parent directory."""
    os.chmod(path, 0o600)


def peer_uid(sock: socket.socket) -> int:
    """Effective uid of the connecting process, from the kernel.

    Unlike anything the client could tell us about itself, this cannot be forged.
    """
    if sys.platform != "darwin":
        # Linux fallback; SO_PEERCRED returns struct ucred {pid, uid, gid}.
        buf = sock.getsockopt(socket.SOL_SOCKET, 17, struct.calcsize("3i"))
        _, uid, _ = struct.unpack("3i", buf)
        return uid
    buf = sock.getsockopt(SOL_LOCAL, LOCAL_PEERCRED, 76)
    version, uid, _ngroups = struct.unpack("=IIh", buf[:10])
    if version != XUCRED_VERSION:
        raise PeerRejected(f"unexpected xucred version {version}")
    return uid


def authorise_peer(sock: socket.socket) -> int:
    """Fail closed: any error checking the peer is a refusal, not a warning."""
    try:
        uid = peer_uid(sock)
    except Exception as exc:  # noqa: BLE001 - deliberately broad, we are failing closed
        raise PeerRejected(f"could not verify peer credentials: {exc}") from exc
    if uid != os.geteuid():
        raise PeerRejected(f"peer uid {uid} is not {os.geteuid()}")
    return uid


def device_fingerprint(udid: str | None) -> str:
    """Salted hash of a device identifier.

    A UDID is a stable, unique, permanent identifier for a physical device. Nothing
    Mirage stores needs the real one — matching a device against a record only needs
    two hashes to agree — so the raw value never reaches disk. The salt is generated
    once per installation, so a fingerprint is meaningless anywhere else.
    """
    import hashlib
    import secrets

    if not udid:
        return "unknown"
    salt_path = state_dir() / SALT_FILE
    if salt_path.exists():
        salt = salt_path.read_bytes()
    else:
        salt = secrets.token_bytes(32)
        salt_path.write_bytes(salt)
        os.chmod(salt_path, 0o600)
    return hashlib.sha256(salt + udid.encode()).hexdigest()[:32]


def redact_udid(udid: str | None) -> str:
    """A UDID is a stable, unique device identifier — treat it like a serial number.

    Logs outlive sessions and get pasted into bug reports, so they never get the
    whole thing.
    """
    if not udid:
        return "<none>"
    return f"{udid[:6]}...{udid[-4:]}" if len(udid) > 12 else "<short>"


def redact_coord(lat: float, lon: float, precision: int = 1) -> str:
    """One decimal place is ~11 km — enough to debug a routing problem, not enough
    to reconstruct where somebody actually was."""
    return f"{lat:.{precision}f},{lon:.{precision}f}"
