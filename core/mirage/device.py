"""Device discovery and preflight.

Most real-world failures here are not bugs, they are unmet preconditions: Developer
Mode off, tunnel not running, device not trusted. Each one gets a specific, actionable
message, because "connection failed" turns into a support ticket and "Developer Mode is
off — enable it in Settings > Privacy & Security, then reboot" does not.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

from .security import redact_udid

log = logging.getLogger(__name__)

TUNNELD_ADDRESS = ("127.0.0.1", 49151)


@dataclass
class DeviceConnection:
    """A connected device plus whatever needs closing to let it go.

    The native tunnel holds an assertion on the device for as long as it is open, so it
    must be released explicitly rather than left to garbage collection.
    """

    rsd: object
    closeable: object | None = None
    transport: str = "unknown"

    @property
    def udid(self) -> str | None:
        return getattr(self.rsd, "udid", None)

    async def aclose(self) -> None:
        if self.closeable is None:
            return
        try:
            await self.closeable.aclose()
        except Exception as exc:  # noqa: BLE001
            log.debug("tunnel close failed: %s", exc)


@dataclass(frozen=True)
class DeviceInfo:
    udid: str
    name: str
    connection: str
    tunnel_ready: bool


class PreflightError(Exception):
    """A precondition the user can fix. `remedy` is shown in the UI verbatim."""

    def __init__(self, message: str, remedy: str) -> None:
        super().__init__(message)
        self.remedy = remedy


async def list_devices() -> list[DeviceInfo]:
    """Every device usbmux knows about, annotated with whether a tunnel exists."""
    from pymobiledevice3 import usbmux

    try:
        muxed = await usbmux.list_devices()
    except Exception as exc:  # noqa: BLE001
        raise PreflightError(
            f"Cannot reach usbmuxd: {exc}",
            "Make sure the Mac can see the device. Unplug and replug the cable.",
        ) from exc

    tunnels = _tunnel_udids()
    out = []
    for d in muxed:
        udid = getattr(d, "serial", None) or getattr(d, "udid", "")
        out.append(
            DeviceInfo(
                udid=udid,
                name=getattr(d, "device_id", None) and f"device {d.device_id}" or udid,
                connection=getattr(d, "connection_type", "usb"),
                tunnel_ready=udid in tunnels,
            )
        )
    return out


def _tunnel_udids() -> set[str]:
    import requests

    try:
        resp = requests.get(f"http://{TUNNELD_ADDRESS[0]}:{TUNNELD_ADDRESS[1]}", timeout=1.5)
        resp.raise_for_status()
        return set(resp.json().keys())
    except Exception:  # noqa: BLE001 - tunneld simply not running is the common case
        return set()


async def connect(udid: str | None = None) -> DeviceConnection:
    """Open a tunnel to `udid`, or to the only device present.

    Two transports, tried in order:

    1. **Apple's native tunnel** via ``remotepairingd``. Runs entirely unprivileged, and
       `NativeRemotedTunnel` is the documented entry point for embedders like this one.
       This is the path Mirage expects to take on macOS.
    2. **An externally-run ``tunneld``**, for hosts where the native path is unavailable.
       That daemon needs root, so Mirage never starts one itself — it only attaches to one
       the user chose to run.

    Raises `PreflightError` with a remedy for every failure the user can act on.
    """
    native_error: str | None = None
    try:
        from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel

        tunnel = NativeRemotedTunnel(serial=udid)
        rsd = await tunnel.aopen()
        log.info("native tunnel up for %s", redact_udid(getattr(rsd, "udid", None)))
        return DeviceConnection(rsd=rsd, closeable=tunnel, transport="native")
    except ImportError:
        native_error = "this build of pymobiledevice3 has no native tunnel support"
    except Exception as exc:  # noqa: BLE001 - any native failure falls through to tunneld
        native_error = str(exc) or exc.__class__.__name__
        log.info("native tunnel unavailable (%s); trying tunneld", native_error)

    try:
        from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid, get_tunneld_devices

        if udid:
            rsd = await get_tunneld_device_by_udid(udid, TUNNELD_ADDRESS)
            rsds = [rsd] if rsd else []
        else:
            rsds = await get_tunneld_devices(TUNNELD_ADDRESS)
    except Exception:  # noqa: BLE001 - tunneld simply not running is the common case
        rsds = []

    if rsds:
        rsd = rsds[0]
        log.info("attached to tunneld for %s", redact_udid(getattr(rsd, "udid", None)))
        return DeviceConnection(rsd=rsd, closeable=None, transport="tunneld")

    devices = await list_devices()
    if not devices:
        raise PreflightError(
            "No iPhone found.",
            "Connect the iPhone by USB and tap Trust on the device. After it is paired "
            "once, it can be used over Wi-Fi on the same network.",
        )

    raise PreflightError(
        f"Found an iPhone but could not open a tunnel to it ({native_error}).",
        "Enable Developer Mode on the iPhone: Settings > Privacy & Security > "
        "Developer Mode, then reboot it and reconnect.",
    )
