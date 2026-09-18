"""Durable record of what we did to the device.

The DVT channel is write-only: `simulateLocationWithLatitude:longitude:` sets a location
and `stopLocationSimulation` clears it, and there is nothing that reads the current state
back. Mirage can therefore never ask a phone whether it is simulating — it can only
remember that it made it so.

That memory is the only thing standing between a user and a device stuck on a false
location, so it is treated accordingly:

- written the moment the *first fix is actually delivered*, not when a session is
  requested, because a session that never reached the device left nothing to undo;
- cleared **only** when a stop is confirmed — never when a notice is dismissed, a window
  is closed, or a session object goes away;
- written atomically and fsynced, so a crash between write and flush cannot lose it;
- survives the engine, the app, and the machine restarting.

A pending restore is recorded the same way. If someone asks to restore while the phone is
unreachable, that intent outlives the attempt and is completed when the device returns.
Finishing a request the user already made is not a silent change.
"""
from __future__ import annotations

import contextlib
import json
import logging
import os
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from .security import device_fingerprint, redact_coord, state_dir

log = logging.getLogger(__name__)

MARKER_FILE = "simulation.json"


@dataclass
class MarkerState:
    active: bool = False
    lat: float | None = None
    lon: float | None = None
    device: str | None = None   # salted fingerprint, never a raw identifier
    since: str | None = None
    restore_pending: bool = False

    def to_json(self) -> dict:
        return asdict(self)


class SimulationMarker:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (state_dir() / MARKER_FILE)
        self._state = self._read()

    # ---- reading --------------------------------------------------------

    @property
    def state(self) -> MarkerState:
        return self._state

    @property
    def active(self) -> bool:
        return self._state.active

    @property
    def restore_pending(self) -> bool:
        return self._state.restore_pending

    def _read(self) -> MarkerState:
        try:
            data = json.loads(self.path.read_text())
            return MarkerState(**{k: data.get(k) for k in MarkerState().to_json()})
        except FileNotFoundError:
            return MarkerState()
        except Exception as exc:  # noqa: BLE001
            # A marker we cannot parse is treated as *active*, not absent. Forgetting
            # that the device may be simulating is the one failure with no recovery, so
            # an unreadable file errs toward telling the user rather than staying quiet.
            log.warning("simulation marker unreadable (%s); assuming a location is set", exc)
            return MarkerState(active=True)

    # ---- writing --------------------------------------------------------

    def mark_active(self, lat: float, lon: float, udid: str | None) -> None:
        """`udid` is fingerprinted on the way in; the raw value is never persisted.

        Nothing reads it back — the marker only needs to say *that* a device is
        simulating, and the fingerprint is enough to tell devices apart if that is ever
        needed. Keeping the real identifier would be a permanent, unique device ID
        sitting in a file for no functional gain.
        """
        if (
            self._state.active
            and self._state.lat == lat
            and self._state.lon == lon
        ):
            return  # unchanged; do not rewrite on every tick
        self._state.active = True
        self._state.lat = lat
        self._state.lon = lon
        self._state.device = device_fingerprint(udid)
        self._state.since = self._state.since or datetime.now(timezone.utc).isoformat()
        self._write()

    def mark_restored(self) -> None:
        """Only ever called after a stop the device actually accepted."""
        if not (self._state.active or self._state.restore_pending):
            return
        self._state = MarkerState()
        self._write()
        log.info("simulation marker cleared — device confirmed back on real GPS")

    def request_restore(self) -> None:
        if self._state.restore_pending:
            return
        self._state.restore_pending = True
        self._write()
        log.info("restore requested while the device was unreachable; will complete on reconnect")

    def _write(self) -> None:
        payload = json.dumps(self._state.to_json(), indent=2)
        tmp = self.path.with_suffix(".tmp")
        try:
            # fsync before the rename: the whole point of this file is to survive a
            # crash, and an unflushed write would not.
            with open(tmp, "w") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except Exception as exc:  # noqa: BLE001
            log.error("could not persist simulation marker: %s", exc)
            with contextlib.suppress(OSError):
                os.unlink(tmp)

    def describe(self) -> str:
        if not self._state.active:
            return "no simulated location recorded"
        where = (
            redact_coord(self._state.lat, self._state.lon)
            if self._state.lat is not None and self._state.lon is not None
            else "unknown"
        )
        return f"simulating near {where} on device {(self._state.device or '?')[:8]}"
