"""Session orchestration: what is being simulated right now, and the tick loop.

Safety invariant: **the device must never be left simulating a location after Mirage
stops.** A user who thinks they are back to their real position when they are not is
strictly worse off than one who was never spoofing. Every exit path — clean stop,
exception, cancellation, process signal — runs through `stop()`, which clears the
override on the device.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import random
import time
from dataclasses import asdict, dataclass, field
from enum import Enum

from collections.abc import Awaitable, Callable

from .geo import LatLon, Polyline
from .injector import Injector
from .marker import SimulationMarker
from .motion import PROFILES, OrnsteinUhlenbeck2D
from .route import DrivePlan, VehicleLimits, build_plan

log = logging.getLogger(__name__)

TICK_HZ = 1.0
# How often to retry the tunnel while a journey is running without a reachable phone.
RECONNECT_INTERVAL = 10.0


class DeviceUnreachable(Exception):
    """The device could not be reached to clear the simulation.

    Distinct from an ordinary failure because the consequence is specific and needs
    saying plainly: the phone is still reporting a false location.
    """

    remedy = (
        "Reconnect the iPhone by USB, or put it back on the same Wi-Fi network as this "
        "Mac, then press Restore Real Location again. Until then it keeps reporting the "
        "simulated position. Restarting the iPhone also clears it."
    )


class Mode(str, Enum):
    IDLE = "idle"
    PINNED = "pinned"
    DRIVING = "driving"


@dataclass
class SessionState:
    mode: Mode = Mode.IDLE
    lat: float | None = None
    lon: float | None = None
    heading: float = 0.0
    speed: float = 0.0          # m/s
    elapsed: float = 0.0        # s into the drive
    total_time: float = 0.0     # s, drive length
    distance: float = 0.0       # m, drive length
    progress: float = 0.0       # 0..1
    eta_remaining: float = 0.0  # s
    profile: str = "stationary"
    error: str | None = None

    # The drive keeps running while the phone is away, so the UI needs to distinguish
    # "nothing is happening" from "the journey continues, we just can't deliver it yet".
    device_connected: bool = True
    device_error: str | None = None
    unreachable_for: float = 0.0   # seconds since delivery last succeeded
    limit_reached: bool = False     # session length hit; holding, not restored

    # Mirage's durable belief about the device, independent of whether a session is
    # running in this process. True means a location was delivered and not yet confirmed
    # cleared — including across crashes and restarts.
    device_dirty: bool = False
    restore_pending: bool = False

    def to_json(self) -> dict:
        d = asdict(self)
        d["mode"] = self.mode.value
        return d


class Session:
    """Owns the injector and the tick loop. One per connected device."""

    def __init__(
        self,
        injector: Injector,
        tick_hz: float = TICK_HZ,
        max_duration: float | None = None,
        udid: str | None = None,
        reconnect: "Callable[[], Awaitable[Injector]] | None" = None,
        marker: SimulationMarker | None = None,
        reconnect_interval: float = RECONNECT_INTERVAL,
    ) -> None:
        self._injector = injector
        # Supplied by the engine: builds a fresh injector against a newly opened tunnel.
        # Needed because a disconnected iPhone keeps reporting its last simulated fix,
        # and the only way to undo that is a working channel.
        self._reconnect = reconnect
        self._reconnect_task: asyncio.Task | None = None
        self._next_reconnect = 0.0
        self._reconnect_interval = reconnect_interval
        self._lost_at: float | None = None
        self._marker = marker or SimulationMarker()
        self._dt = 1.0 / tick_hz
        # A cap the owner set during consent. Enforced here rather than in the UI so it
        # holds even for a client talking to the socket directly.
        self.max_duration = max_duration
        self.udid = udid
        self._task: asyncio.Task | None = None
        self._plan: DrivePlan | None = None
        self._anchor: LatLon | None = None
        self._jitter = OrnsteinUhlenbeck2D(PROFILES["stationary"])
        self._started_at = 0.0
        # Seeded from the durable marker, so a freshly started engine already knows the
        # device may be simulating from a run that never got to clean up.
        self.state = SessionState(
            device_dirty=self._marker.active,
            restore_pending=self._marker.restore_pending,
        )
        self._subscribers: list[asyncio.Queue] = []

    # ---- subscriptions -------------------------------------------------

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=64)
        self._subscribers.append(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        with contextlib.suppress(ValueError):
            self._subscribers.remove(q)

    def _emit(self) -> None:
        payload = self.state.to_json()
        for q in list(self._subscribers):
            try:
                q.put_nowait(payload)
            except asyncio.QueueFull:
                # A stalled UI must never stall the tick loop that is driving the phone.
                with contextlib.suppress(asyncio.QueueEmpty):
                    q.get_nowait()
                with contextlib.suppress(asyncio.QueueFull):
                    q.put_nowait(payload)

    # ---- lifecycle -----------------------------------------------------

    async def pin(self, lat: float, lon: float, profile: str = "stationary") -> None:
        """Hold a fixed position, with drift so it does not look frozen."""
        await self._restart(
            mode=Mode.PINNED,
            anchor=LatLon(lat, lon),
            plan=None,
            profile=profile,
        )

    async def drive(
        self,
        points: list[tuple[float, float]],
        expected_travel_time: float | None = None,
        seed: int | None = None,
        limits: VehicleLimits | None = None,
        include_stops: bool = True,
        waypoint_stops: dict[int, float] | None = None,
    ) -> DrivePlan:
        """Play a route.

        `expected_travel_time` is the traffic-aware driving time in seconds.
        `waypoint_stops` maps a vertex index to how long to wait there — the user's own
        stops on a multi-leg trip.
        """
        poly = Polyline([LatLon(lat, lon) for lat, lon in points])
        plan = build_plan(
            poly,
            expected_travel_time=expected_travel_time,
            limits=limits,
            seed=seed if seed is not None else random.randrange(1 << 30),
            include_stops=include_stops,
            waypoint_stops=waypoint_stops,
        )
        await self._restart(mode=Mode.DRIVING, anchor=None, plan=plan, profile="driving")
        return plan

    async def _restart(self, *, mode: Mode, anchor, plan, profile: str) -> None:
        await self._cancel_task()
        self._anchor = anchor
        self._plan = plan
        self._jitter = OrnsteinUhlenbeck2D(PROFILES.get(profile, PROFILES["stationary"]))
        self._started_at = time.monotonic()
        # Don't inherit a backoff timer set by an earlier failure: a new session is a
        # fresh reason to try the device immediately.
        self._next_reconnect = 0.0
        self.state = SessionState(
            device_dirty=self._marker.active,
            restore_pending=self._marker.restore_pending,
            mode=mode,
            profile=profile,
            total_time=plan.total_time if plan else 0.0,
            distance=plan.distance if plan else 0.0,
            eta_remaining=plan.total_time if plan else 0.0,
        )
        await self._injector.open()
        self._task = asyncio.create_task(self._run(), name=f"mirage-{mode.value}")

    async def stop(self) -> None:
        """End the session and return the device to real GPS.

        Shares `restore()`'s recovery path: if the channel died with the session, the
        clear is retried on a fresh one rather than failing outright.
        """
        await self.restore()
        log.info("session stopped, device restored to real GPS")

    async def restore(self) -> None:
        """Clear any simulation on the device, whatever this session believes.

        `stop()` tidies up a session *this* process started. `restore()` does not care:
        it opens the channel and clears unconditionally. That matters because the failure
        mode this guards against is a previous run dying without its shutdown path — the
        device is still simulating, and no session object knows about it.

        Clearing when nothing is simulated is a no-op on the device, so this is always
        safe to call.
        """
        await self._cancel_task()
        try:
            await self._injector.open()
            await self._injector.clear()
        except Exception as first_error:  # noqa: BLE001
            # The channel is probably dead — the usual cause is the phone being
            # unplugged or dropping off the network mid-session. Rebuild it and try
            # once more before giving up.
            log.info("restore failed on the existing channel (%s); reconnecting", first_error)
            if self._reconnect is None:
                raise
            try:
                with contextlib.suppress(Exception):
                    await self._injector.close()
                self._injector = await self._reconnect()
                await self._injector.open()
                await self._injector.clear()
            except Exception as retry_error:
                # The intent outlives the failed attempt. Completing a restore the user
                # already asked for, once the device is reachable again, is finishing
                # their request — not changing things behind their back.
                self._marker.request_restore()
                self.state.restore_pending = True
                self.state.error = (
                    "Your iPhone is not reachable, so it is still reporting the "
                    "simulated location. Mirage will restore it as soon as the phone "
                    "reconnects, or you can press Restore again then."
                )
                self._emit()
                self._schedule_reconnect()
                raise DeviceUnreachable(str(retry_error)) from retry_error

        self._marker.mark_restored()
        self.state = SessionState(mode=Mode.IDLE)
        self.state.device_dirty = False
        self.state.restore_pending = False
        self._emit()
        log.info("device restored to real GPS")

    async def close(self) -> None:
        await self._cancel_task()
        await self._injector.close()

    async def _cancel_task(self) -> None:
        """Tear down the tick loop without inheriting however it died.

        Awaiting a task that already failed re-raises its exception. Suppressing only
        `CancelledError` meant that a tick loop killed by the device going away made
        `stop()` and `restore()` raise too — so the one control that could recover the
        situation was the one guaranteed to fail. The failure was already logged where
        it happened; here it is only cleanup.
        """
        if self._reconnect_task is not None:
            self._reconnect_task.cancel()
            with contextlib.suppress(BaseException):
                await self._reconnect_task
            self._reconnect_task = None
        if self._task is None:
            return
        self._task.cancel()
        with contextlib.suppress(BaseException):
            await self._task
        self._task = None

    # ---- tick loop -----------------------------------------------------

    async def _run(self) -> None:
        try:
            next_tick = time.monotonic()
            while True:
                await self._tick()
                next_tick += self._dt
                # Sleep to an absolute deadline so injection latency does not make
                # the simulated clock drift behind the real one.
                await asyncio.sleep(max(0.0, next_tick - time.monotonic()))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.exception("tick loop failed")
            self.state.error = str(exc)
            self._emit()
            with contextlib.suppress(Exception):
                await self._injector.clear()
            raise

    async def _tick(self) -> None:
        elapsed = time.monotonic() - self._started_at

        if (
            self.max_duration is not None
            and not self.state.limit_reached
            and elapsed >= self.max_duration
        ):
            self._hold_here()

        if self._plan is not None:
            base, heading, speed = self._plan.state_at(elapsed)
            self.state.elapsed = min(elapsed, self._plan.total_time)
            self.state.heading = heading
            self.state.speed = speed
            self.state.progress = (
                min(1.0, elapsed / self._plan.total_time) if self._plan.total_time else 1.0
            )
            self.state.eta_remaining = max(0.0, self._plan.total_time - elapsed)
            if elapsed >= self._plan.total_time:
                # Arrived. Hold the destination with stationary drift rather than
                # stopping dead, which would look like the phone switched off.
                self._anchor = base
                self._plan = None
                self.state.mode = Mode.PINNED
                self.state.profile = "stationary"
                self._jitter = OrnsteinUhlenbeck2D(PROFILES["stationary"])
        elif self._anchor is not None:
            base, self.state.speed = self._anchor, 0.0
        else:
            return

        fix = self._jitter.apply(base, self._dt)
        await self._deliver(fix)
        self.state.lat, self.state.lon = fix.lat, fix.lon
        self._emit()

    def _hold_here(self) -> None:
        """Freeze the journey where it is and keep reporting that position.

        The session length is a reminder, not a kill switch: it stops the drive
        advancing and raises a flag, but never restores the device. Undoing a location
        someone chose is their decision, and they may not be at the Mac to make it.
        """
        if self.state.lat is not None and self.state.lon is not None:
            self._anchor = LatLon(self.state.lat, self.state.lon)
        self._plan = None
        self.state.mode = Mode.PINNED
        self.state.speed = 0.0
        self.state.profile = "stationary"
        self.state.limit_reached = True
        self._jitter = OrnsteinUhlenbeck2D(PROFILES["stationary"])
        log.info("session length reached — holding position, device not restored")

    async def _deliver(self, fix: LatLon) -> None:
        """Send one fix, tolerating a phone that is not currently reachable.

        A failure here must not end the journey. The trajectory is driven by the clock,
        not by what got delivered, so a drive continues through a disconnection and the
        first fix after reconnecting is wherever the driver would actually be by then —
        no rewind, no replay of the gap.
        """
        try:
            await self._injector.set(fix.lat, fix.lon)
            # Recorded only once the device has actually accepted a fix: a session that
            # never reached the phone left nothing to undo.
            self._marker.mark_active(fix.lat, fix.lon, self.udid)
            self.state.device_dirty = True
        except Exception as exc:  # noqa: BLE001
            if self.state.device_connected:
                log.warning("device unreachable (%s) — journey continues", exc)
                self._lost_at = time.monotonic()
            self.state.device_connected = False
            self.state.device_error = str(exc)
            self.state.unreachable_for = (
                time.monotonic() - self._lost_at if self._lost_at else 0.0
            )
            self._schedule_reconnect()
            return

        if not self.state.device_connected:
            gap = self.state.unreachable_for
            log.info("device back after %.0fs — resumed at the current point", gap)
        self.state.device_connected = True
        self.state.device_error = None
        self.state.unreachable_for = 0.0
        self._lost_at = None

    def _schedule_reconnect(self) -> None:
        """Retry in the background, so a slow connect never stalls the tick loop and
        the simulated clock keeps pace with the real one."""
        if self._reconnect is None:
            return
        now = time.monotonic()
        if now < self._next_reconnect:
            return
        if self._reconnect_task is not None and not self._reconnect_task.done():
            return
        self._next_reconnect = now + self._reconnect_interval
        self._reconnect_task = asyncio.create_task(self._reconnect_once())

    async def _reconnect_once(self) -> None:
        try:
            with contextlib.suppress(Exception):
                await self._injector.close()
            self._injector = await self._reconnect()  # type: ignore[misc]
            await self._injector.open()
            log.info("tunnel re-established")

            if self._marker.restore_pending:
                await self._injector.clear()
                self._marker.mark_restored()
                self.state = SessionState(mode=Mode.IDLE)
                self._emit()
                log.info("completed the restore that was requested while offline")
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.debug("reconnect attempt failed: %s", exc)
