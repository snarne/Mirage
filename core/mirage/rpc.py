"""Newline-delimited JSON control channel over a Unix domain socket.

Not TCP. See `security.py` for why: a localhost port is reachable by every process on
the machine and by web content via DNS rebinding, and this channel can move the user's
apparent location anywhere on earth.

Protocol: one JSON object per line.
  -> {"id": 1, "method": "session.pin", "params": {"lat": .., "lon": ..}}
  <- {"id": 1, "ok": true, "result": {...}}
  <- {"event": "state", "data": {...}}          (unsolicited, after subscribe)
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
from typing import Any, Awaitable, Callable

from .consent import AgeAttestation, ConsentError, ConsentStore, Eligibility, Grants
from .device import PreflightError, list_devices
from .route import VehicleLimits
from .security import PeerRejected, authorise_peer, harden_socket_file, socket_path
from .session import DeviceUnreachable, Session

log = logging.getLogger(__name__)

MAX_LINE = 1 << 20  # a route polyline can be large; anything past 1 MiB is abuse


class RpcServer:
    def __init__(self, session: Session, path=None, consent: ConsentStore | None = None,
                 eligibility: Eligibility | None = None) -> None:
        self.session = session
        self.path = path or socket_path()
        self.consent = consent or ConsentStore()
        self.eligibility = eligibility or Eligibility()
        self._server: asyncio.AbstractServer | None = None
        self._handlers: dict[str, Callable[[dict], Awaitable[Any]]] = {
            "status": self._status,
            "devices.list": self._devices,
            "session.pin": self._pin,
            "session.drive": self._drive,
            "session.stop": self._stop,
            "session.restore": self._restore,
            "session.state": self._state,
            "consent.status": self._consent_status,
            "consent.grant": self._consent_grant,
            "consent.revoke": self._consent_revoke,
            "device.eligibility": self._device_eligibility,
        }

    async def start(self) -> None:
        if self.path.exists():
            self.path.unlink()
        # Create with a restrictive umask so there is no window where the socket
        # exists group/world-accessible between bind and chmod.
        old = os.umask(0o077)
        try:
            self._server = await asyncio.start_unix_server(self._handle, path=str(self.path))
        finally:
            os.umask(old)
        harden_socket_file(self.path)
        log.info("control socket listening at %s (0600)", self.path)

    async def serve_forever(self) -> None:
        if self._server is None:
            await self.start()
        async with self._server:  # type: ignore[union-attr]
            await self._server.serve_forever()  # type: ignore[union-attr]

    async def close(self) -> None:
        if self._server is not None:
            self._server.close()
            with contextlib.suppress(Exception):
                await self._server.wait_closed()
        with contextlib.suppress(FileNotFoundError):
            self.path.unlink()

    # ---- connection handling -------------------------------------------

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        sock = writer.get_extra_info("socket")
        try:
            authorise_peer(sock)
        except PeerRejected as exc:
            log.warning("rejected connection: %s", exc)
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            return

        queue = self.session.subscribe()
        pump = asyncio.create_task(self._pump_events(queue, writer))
        try:
            while True:
                try:
                    line = await reader.readuntil(b"\n")
                except (asyncio.IncompleteReadError, ConnectionResetError):
                    break
                except asyncio.LimitOverrunError:
                    log.warning("oversized request, dropping connection")
                    break
                if len(line) > MAX_LINE:
                    break
                await self._dispatch(line, writer)
        finally:
            pump.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await pump
            self.session.unsubscribe(queue)
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    async def _pump_events(self, queue: asyncio.Queue, writer: asyncio.StreamWriter) -> None:
        while True:
            data = await queue.get()
            await self._send(writer, {"event": "state", "data": data})

    async def _dispatch(self, line: bytes, writer: asyncio.StreamWriter) -> None:
        try:
            msg = json.loads(line)
            req_id, method, params = msg.get("id"), msg["method"], msg.get("params") or {}
        except Exception as exc:  # noqa: BLE001
            await self._send(writer, {"ok": False, "error": f"malformed request: {exc}"})
            return

        handler = self._handlers.get(method)
        if handler is None:
            await self._send(writer, {"id": req_id, "ok": False, "error": f"unknown method {method!r}"})
            return
        try:
            result = await handler(params)
            await self._send(writer, {"id": req_id, "ok": True, "result": result})
        except DeviceUnreachable as exc:
            await self._send(writer, {
                "id": req_id, "ok": False,
                "error": "Your iPhone is not reachable, so it is still reporting the "
                         "simulated location.",
                "remedy": DeviceUnreachable.remedy,
                "device_unreachable": True,
            })
        except ConsentError as exc:
            await self._send(
                writer, {"id": req_id, "ok": False, "error": str(exc), "remedy": exc.remedy}
            )
        except PreflightError as exc:
            await self._send(
                writer, {"id": req_id, "ok": False, "error": str(exc), "remedy": exc.remedy}
            )
        except Exception as exc:  # noqa: BLE001
            log.exception("handler %s failed", method)
            await self._send(writer, {"id": req_id, "ok": False, "error": str(exc)})

    async def _send(self, writer: asyncio.StreamWriter, obj: dict) -> None:
        try:
            writer.write(json.dumps(obj).encode() + b"\n")
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass

    # ---- methods --------------------------------------------------------

    async def _status(self, _p: dict) -> dict:
        return {"version": "0.1.0", "state": self.session.state.to_json()}

    async def _devices(self, _p: dict) -> list[dict]:
        return [d.__dict__ for d in await list_devices()]

    async def _pin(self, p: dict) -> dict:
        lat, lon = float(p["lat"]), float(p["lon"])
        _validate_coord(lat, lon)
        self._authorise("pin")
        await self.session.pin(lat, lon, profile=p.get("profile", "stationary"))
        return self.session.state.to_json()

    async def _drive(self, p: dict) -> dict:
        points = [(float(a), float(b)) for a, b in p["points"]]
        if len(points) < 2:
            raise ValueError("a route needs at least two points")
        for lat, lon in points:
            _validate_coord(lat, lon)
        self._authorise("drive")
        limits = VehicleLimits(**p["limits"]) if p.get("limits") else None
        stops = _parse_stops(p.get("stops"))
        plan = await self.session.drive(
            points,
            expected_travel_time=p.get("expected_travel_time"),
            seed=p.get("seed"),
            limits=limits,
            include_stops=p.get("include_stops", True),
            waypoint_stops=stops,
        )
        return {
            "total_time": plan.total_time,
            "distance": plan.distance,
            "requested_eta": plan.requested_eta,
            "eta_achievable": plan.eta_achievable,
            "stop_seconds": sum(stops.values()) if stops else 0.0,
            "state": self.session.state.to_json(),
        }

    async def _stop(self, _p: dict) -> dict:
        await self.session.stop()
        return self.session.state.to_json()

    async def _restore(self, _p: dict) -> dict:
        """Deliberately *not* behind the consent gate.

        Consent governs changing the reported location. Putting it back is the safe
        direction, and must never be refused — least of all because a grant expired
        while a session was running.
        """
        await self.session.restore()
        return self.session.state.to_json()

    async def _state(self, _p: dict) -> dict:
        return self.session.state.to_json()

    # ---- consent --------------------------------------------------------

    def _authorise(self, action: str) -> None:
        """Every location-changing call goes through here.

        Refuses outright on a managed device, regardless of any consent on file: a
        supervised or MDM-enrolled iPhone is someone else's to set policy on.
        """
        blocking = self.eligibility.blocking_reasons
        if blocking:
            raise ConsentError(
                "This iPhone is managed. " + blocking[0],
                remedy="Mirage does not run on supervised, MDM-enrolled, or "
                       "restriction-managed devices.",
            )
        record = self.consent.require(action, self.session.udid)
        self.session.max_duration = record.grants.max_session_minutes * 60

    async def _consent_status(self, _p: dict) -> dict:
        record = self.consent.load()
        return {
            "granted": record is not None and not record.expired,
            "record": record.to_json() if record else None,
            "eligibility": self.eligibility.to_json(),
        }

    async def _consent_grant(self, p: dict) -> dict:
        age = AgeAttestation(
            meets_threshold=bool(p.get("meets_threshold", False)),
            threshold=int(p.get("threshold", 18)),
            lower_bound=p.get("lower_bound"),
            upper_bound=p.get("upper_bound"),
            declaration=str(p.get("declaration", "unknown")),
            parental_controls_active=bool(p.get("parental_controls_active", False)),
            source=str(p.get("source", "unknown")),
        )
        grants = Grants(**(p.get("grants") or {}))
        record = self.consent.grant(age=age, grants=grants, udid=self.session.udid)
        self.session.max_duration = grants.max_session_minutes * 60
        return record.to_json()

    async def _consent_revoke(self, _p: dict) -> dict:
        self.consent.revoke()
        await self.session.stop()
        return {"granted": False}

    async def _device_eligibility(self, _p: dict) -> dict:
        return self.eligibility.to_json()


def _parse_stops(raw) -> dict[int, float] | None:
    """`[{"index": 57, "seconds": 300}, ...]` → `{57: 300.0}`.

    Durations are capped: a "stop" long enough to outlast the session limit is a pin,
    not a stop, and unbounded values would let one call pin the device indefinitely.
    """
    if not raw:
        return None
    out: dict[int, float] = {}
    for entry in raw:
        index = int(entry["index"])
        seconds = float(entry["seconds"])
        if index < 0:
            raise ValueError(f"stop index out of range: {index}")
        if not (0 <= seconds <= 24 * 3600):
            raise ValueError(f"stop duration out of range: {seconds}")
        out[index] = out.get(index, 0.0) + seconds
    return out


def _validate_coord(lat: float, lon: float) -> None:
    if not (-90.0 <= lat <= 90.0) or not (-180.0 <= lon <= 180.0):
        raise ValueError(f"coordinate out of range: {lat},{lon}")
