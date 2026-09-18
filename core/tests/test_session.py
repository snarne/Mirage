import asyncio
import shutil
import tempfile
import pytest
from mirage.route import VehicleLimits
from mirage.geo import LatLon, destination, haversine
from mirage.injector import MockInjector
from mirage.session import Mode, Session

SF = LatLon(37.7749, -122.4194)


@pytest.fixture(autouse=True)
def isolated_state(monkeypatch):
    """Sessions write a durable simulation marker. Without this the suite would scribble
    on the real installation's state — and, worse, read its belief about the device."""
    tmp = tempfile.mkdtemp(prefix="mrgsess")
    monkeypatch.setenv("MIRAGE_STATE_DIR", tmp)
    yield
    shutil.rmtree(tmp, ignore_errors=True)


def route(n=30, spacing=60.0):
    pts = [SF]
    for _ in range(n):
        pts.append(destination(pts[-1], 45.0, spacing))
    return [(p.lat, p.lon) for p in pts]


@pytest.mark.asyncio
async def test_pin_injects_and_jitters():
    inj = MockInjector()
    s = Session(inj, tick_hz=50.0)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.2)
    await s.stop()

    assert inj.opened
    assert len(inj.fixes) >= 3
    # Every fix is near the pin, but not identical to it — a frozen coordinate is
    # the loudest possible tell.
    for lat, lon in inj.fixes:
        assert haversine(SF, LatLon(lat, lon)) < 60.0
    assert len({f for f in inj.fixes}) > 1, "position never moved — looks simulated"


@pytest.mark.asyncio
async def test_stop_clears_the_device():
    inj = MockInjector()
    s = Session(inj, tick_hz=50.0)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.05)
    await s.stop()
    assert inj.cleared >= 1
    assert s.state.mode is Mode.IDLE


@pytest.mark.asyncio
async def test_close_clears_even_without_stop():
    """The safety invariant: no exit path leaves the device simulating."""
    inj = MockInjector()
    s = Session(inj, tick_hz=50.0)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.05)
    await s.close()
    assert inj.cleared >= 1


# A test that wants a drive to finish in under a second has to let the vehicle
# accelerate unrealistically; physics is not negotiable now that the ETA scaler
# clamps. Keep the two concerns separate.
BRISK = VehicleLimits(v_max=200.0, a_accel=400.0, a_brake=400.0, a_lateral=400.0)


@pytest.mark.asyncio
async def test_drive_progresses_along_the_route():
    inj = MockInjector()
    s = Session(inj, tick_hz=100.0)
    plan = await s.drive(route(), expected_travel_time=120.0)
    assert plan.eta_achievable
    assert plan.total_time == pytest.approx(120.0, rel=0.05)
    await asyncio.sleep(1.0)
    assert s.state.mode is Mode.DRIVING
    assert 0.0 < s.state.progress < 1.0
    assert s.state.speed > 0.0          # accelerating away from the start
    assert s.state.eta_remaining < plan.total_time
    await s.stop()
    assert len(inj.fixes) > 10


@pytest.mark.asyncio
async def test_drive_arrives_and_holds_destination():
    inj = MockInjector()
    s = Session(inj, tick_hz=200.0)
    plan = await s.drive(route(n=10, spacing=10.0), limits=BRISK, include_stops=False)
    assert plan.total_time < 2.0
    await asyncio.sleep(plan.total_time + 0.4)
    assert s.state.mode is Mode.PINNED          # arrived, now holding with drift
    assert s.state.progress == pytest.approx(1.0)
    await s.stop()

    first, last = LatLon(*inj.fixes[0]), LatLon(*inj.fixes[-1])
    assert haversine(first, last) > 60.0        # actually travelled the 100 m route


@pytest.mark.asyncio
async def test_drive_emits_state_events():
    inj = MockInjector()
    s = Session(inj, tick_hz=100.0)
    q = s.subscribe()
    await s.drive(route(), expected_travel_time=120.0)
    ev = await asyncio.wait_for(q.get(), timeout=2.0)
    assert ev["mode"] in ("driving", "pinned")
    assert ev["lat"] is not None
    await s.stop()


@pytest.mark.asyncio
async def test_slow_subscriber_does_not_stall_the_device():
    """A hung UI must never stop the tick loop mid-drive."""
    inj = MockInjector()
    s = Session(inj, tick_hz=200.0)
    s.subscribe()  # never drained
    await s.drive(route(), expected_travel_time=120.0)
    await asyncio.sleep(0.5)
    await s.stop()
    assert len(inj.fixes) > 20


# ------------------------------------------------- device lost mid-session

class DyingInjector:
    """Fails the way a real channel does when the iPhone goes away."""

    def __init__(self, fail_after: int = 2) -> None:
        self.fail_after = fail_after
        self.sets = 0
        self.cleared = 0
        self.opened = False

    async def open(self, force: bool = False) -> None:
        self.opened = True

    async def set(self, lat: float, lon: float) -> None:
        self.sets += 1
        if self.sets > self.fail_after:
            raise RuntimeError("Channel is closed")

    async def clear(self) -> None:
        raise RuntimeError("Channel is closed")

    async def close(self) -> None:
        self.opened = False


@pytest.mark.asyncio
async def test_restore_does_not_inherit_a_dead_tick_loops_exception():
    """The regression: a tick loop killed by the device disconnecting made restore()
    raise too, so the one control that could recover was the one guaranteed to fail."""
    dying = DyingInjector(fail_after=1)
    healthy = MockInjector()

    async def reconnect():
        return healthy

    s = Session(dying, tick_hz=100.0, reconnect=reconnect)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.3)          # let the tick loop die

    await s.stop()                    # must not raise
    assert healthy.cleared >= 1, "should have reconnected and cleared the device"


@pytest.mark.asyncio
async def test_restore_reconnects_when_the_channel_is_dead():
    dying = DyingInjector(fail_after=1)
    healthy = MockInjector()

    async def reconnect():
        return healthy

    s = Session(dying, tick_hz=100.0, reconnect=reconnect)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.3)

    await s.restore()
    assert healthy.cleared >= 1
    assert s.state.mode is Mode.IDLE


@pytest.mark.asyncio
async def test_unreachable_device_reports_the_consequence_plainly():
    """When the phone genuinely cannot be reached, the user must be told that it is
    still reporting a false location — not just that something failed."""
    from mirage.session import DeviceUnreachable

    async def reconnect():
        raise RuntimeError("no device found")

    s = Session(DyingInjector(fail_after=0), tick_hz=100.0, reconnect=reconnect)
    with pytest.raises(DeviceUnreachable):
        await s.restore()
    assert "still reporting" in (s.state.error or "")
    assert "Reconnect" in DeviceUnreachable.remedy


@pytest.mark.asyncio
async def test_stop_without_a_reconnect_hook_still_surfaces_the_error():
    s = Session(DyingInjector(fail_after=0), tick_hz=100.0)
    with pytest.raises(Exception):
        await s.restore()


# ------------------------------------- journey continues through a disconnect

class FlakyInjector:
    """Reachable, then not, then reachable again — a phone leaving and rejoining Wi-Fi."""

    def __init__(self) -> None:
        self.reachable = True
        self.fixes: list[tuple[float, float]] = []
        self.cleared = 0
        self.opened = False

    async def open(self, force: bool = False) -> None:
        self.opened = True

    async def set(self, lat: float, lon: float) -> None:
        if not self.reachable:
            raise RuntimeError("Channel is closed")
        self.fixes.append((lat, lon))

    async def clear(self) -> None:
        if not self.reachable:
            raise RuntimeError("Channel is closed")
        self.cleared += 1

    async def close(self) -> None:
        self.opened = False


@pytest.mark.asyncio
async def test_drive_survives_the_phone_disappearing():
    """Losing the phone must not end the journey."""
    inj = FlakyInjector()
    s = Session(inj, tick_hz=100.0)
    await s.drive(route(), expected_travel_time=120.0)

    await asyncio.sleep(0.2)
    assert s.state.device_connected

    inj.reachable = False
    await asyncio.sleep(0.3)
    assert not s.state.device_connected
    assert s.state.mode is Mode.DRIVING, "the journey should still be running"
    assert s.state.progress > 0

    inj.reachable = True
    await asyncio.sleep(0.2)
    assert s.state.device_connected
    await s.stop()


@pytest.mark.asyncio
async def test_journey_advances_during_the_outage_and_resumes_in_place():
    """The clock drives the trajectory, not the delivery. When the phone comes back it
    picks up where the driver would actually be — no rewind, no replay of the gap."""
    inj = FlakyInjector()
    s = Session(inj, tick_hz=100.0)
    await s.drive(route(n=60, spacing=60.0), limits=BRISK, include_stops=False)

    await asyncio.sleep(0.3)
    inj.reachable = False
    last_before = LatLon(*inj.fixes[-1])
    progress_before = s.state.progress
    delivered_during = len(inj.fixes)

    await asyncio.sleep(0.6)                      # a gap with nothing delivered
    assert len(inj.fixes) == delivered_during, "nothing should be delivered while away"

    inj.reachable = True
    await asyncio.sleep(0.2)
    first_after = LatLon(*inj.fixes[delivered_during])

    assert s.state.progress > progress_before, "the journey kept going while away"
    # The first fix after reconnecting is further along the route — the position the
    # driver would have reached, not the point it froze at.
    assert haversine(last_before, first_after) > 20.0
    await s.stop()


@pytest.mark.asyncio
async def test_reconnect_is_attempted_in_the_background():
    healthy = MockInjector()
    dead = FlakyInjector()
    dead.reachable = False
    calls = {"n": 0}

    async def reconnect():
        calls["n"] += 1
        return healthy

    s = Session(dead, tick_hz=100.0, reconnect=reconnect)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.4)
    assert calls["n"] >= 1, "should have tried to re-establish the tunnel"
    await s.stop()


# ----------------------------------------------- session length holds, never clears

@pytest.mark.asyncio
async def test_session_limit_holds_position_and_does_not_restore():
    """The limit is a reminder, not a kill switch. Undoing a location the user chose is
    their decision, and they may not be at the Mac to make it."""
    inj = MockInjector()
    s = Session(inj, tick_hz=100.0, max_duration=0.3)
    await s.drive(route(), expected_travel_time=60.0)

    await asyncio.sleep(0.6)
    assert s.state.limit_reached
    assert s.state.mode is Mode.PINNED
    assert inj.cleared == 0, "must not restore the device on its own"

    # And it keeps reporting the held position rather than going silent.
    count = len(inj.fixes)
    await asyncio.sleep(0.2)
    assert len(inj.fixes) > count
    await s.stop()


@pytest.mark.asyncio
async def test_limit_holds_where_the_drive_had_reached():
    inj = MockInjector()
    s = Session(inj, tick_hz=100.0, max_duration=0.5)
    await s.drive(route(n=60, spacing=60.0), limits=BRISK, include_stops=False)
    await asyncio.sleep(0.9)

    held = LatLon(s.state.lat, s.state.lon)
    start = LatLon(*inj.fixes[0])
    assert haversine(start, held) > 20.0, "should hold partway along, not at the start"
    assert s.state.speed == 0.0
    await s.stop()


@pytest.mark.asyncio
async def test_arrival_holds_the_destination_indefinitely():
    inj = MockInjector()
    s = Session(inj, tick_hz=200.0)
    plan = await s.drive(route(n=10, spacing=10.0), limits=BRISK, include_stops=False)
    await asyncio.sleep(plan.total_time + 0.4)

    assert s.state.mode is Mode.PINNED
    assert inj.cleared == 0
    count = len(inj.fixes)
    await asyncio.sleep(0.2)
    assert len(inj.fixes) > count, "should keep reporting the destination"
    await s.stop()


# ---------------------------------------- Mirage must never forget the device

@pytest.mark.asyncio
async def test_a_fresh_session_inherits_the_marker_belief(tmp_path):
    """The engine restarting must not lose the knowledge that the phone is simulating.
    This is the property the whole marker exists for."""
    from mirage.marker import SimulationMarker

    marker = SimulationMarker(tmp_path / "simulation.json")
    marker.mark_active(35.6762, 139.6503, "UDID")

    # A brand new engine process, with no session history of its own.
    reborn = Session(MockInjector(), marker=SimulationMarker(tmp_path / "simulation.json"))
    assert reborn.state.device_dirty
    assert reborn.state.mode is Mode.IDLE, "not running anything — but the device is dirty"


@pytest.mark.asyncio
async def test_marker_is_only_set_once_a_fix_is_delivered(tmp_path):
    """A session that never reached the phone left nothing to undo."""
    from mirage.marker import SimulationMarker

    marker = SimulationMarker(tmp_path / "simulation.json")
    unreachable = DyingInjector(fail_after=0)
    s = Session(unreachable, tick_hz=100.0, marker=marker)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.2)
    assert not marker.active, "nothing was delivered, so nothing needs undoing"


@pytest.mark.asyncio
async def test_marker_clears_only_on_a_confirmed_restore(tmp_path):
    from mirage.marker import SimulationMarker

    marker = SimulationMarker(tmp_path / "simulation.json")
    inj = MockInjector()
    s = Session(inj, tick_hz=100.0, marker=marker)
    await s.pin(SF.lat, SF.lon)
    await asyncio.sleep(0.15)
    assert marker.active

    await s.restore()
    assert not marker.active
    assert not s.state.device_dirty


@pytest.mark.asyncio
async def test_restore_requested_while_offline_completes_on_reconnect(tmp_path):
    """The user's intent outlives the failed attempt. This is what stops someone being
    stranded because they pressed Restore at the wrong moment."""
    from mirage.marker import SimulationMarker
    from mirage.session import DeviceUnreachable

    marker = SimulationMarker(tmp_path / "simulation.json")
    marker.mark_active(1.0, 2.0, "UDID")

    healthy = MockInjector()
    reachable = {"yet": False}

    async def reconnect():
        if not reachable["yet"]:
            raise RuntimeError("no device found")
        return healthy

    s = Session(DyingInjector(fail_after=0), tick_hz=100.0,
                reconnect=reconnect, marker=marker, reconnect_interval=0.05)

    with pytest.raises(DeviceUnreachable):
        await s.restore()
    assert marker.restore_pending, "the request must survive the failure"

    # The phone comes back.
    reachable["yet"] = True
    await s.pin(SF.lat, SF.lon)          # any activity drives the reconnect loop
    await asyncio.sleep(0.5)
    assert healthy.cleared >= 1 or not marker.restore_pending
