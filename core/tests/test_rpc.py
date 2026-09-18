import asyncio
import json
import pathlib
import shutil
import tempfile
import os
import stat
import pytest
from mirage.consent import AgeAttestation, ConsentStore, Eligibility, Grants
from mirage.injector import MockInjector
from mirage.rpc import RpcServer
from mirage.session import Session

ADULT = AgeAttestation(meets_threshold=True, lower_bound=18, declaration="confirmed",
                       source="DeclaredAgeRange")
UDID = "test-device-a"


class Client:
    def __init__(self, r, w):
        self.r, self.w, self._id = r, w, 0

    async def call(self, method, **params):
        self._id += 1
        self.w.write(json.dumps({"id": self._id, "method": method, "params": params}).encode() + b"\n")
        await self.w.drain()
        while True:
            line = await asyncio.wait_for(self.r.readline(), timeout=3.0)
            msg = json.loads(line)
            if msg.get("id") == self._id:
                return msg

    async def close(self):
        self.w.close()


def _make_server(tmp, *, consent=True, eligibility=None, grants=None):
    sock = pathlib.Path(tmp) / "c.sock"
    session = Session(MockInjector(), tick_hz=50.0, udid=UDID)
    store = ConsentStore(path=pathlib.Path(tmp) / "consent.json")
    if consent:
        store.grant(age=ADULT, grants=grants or Grants(allow_pin=True, allow_drive=True),
                    udid=UDID)
    srv = RpcServer(session, path=sock, consent=store,
                    eligibility=eligibility or Eligibility(checked=True))
    return srv, session, sock


@pytest.fixture(autouse=True)
def isolated_state(monkeypatch):
    monkeypatch.setenv("MIRAGE_STATE_DIR", tempfile.mkdtemp(prefix="mrgstate", dir="/tmp"))


@pytest.fixture
async def server():
    # pytest's tmp_path is far too long for AF_UNIX's 104-byte sun_path on macOS.
    tmp = tempfile.mkdtemp(prefix="mrg", dir="/tmp")
    srv, session, sock = _make_server(tmp)
    await srv.start()
    serving = asyncio.create_task(srv.serve_forever())
    yield srv, session, sock
    serving.cancel()
    await session.close()
    await srv.close()
    shutil.rmtree(tmp, ignore_errors=True)


@pytest.mark.asyncio
async def test_socket_is_owner_only(server):
    _, _, sock = server
    mode = os.stat(sock).st_mode
    assert stat.S_IMODE(mode) == 0o600
    assert not (mode & stat.S_IRGRP) and not (mode & stat.S_IROTH)


@pytest.mark.asyncio
async def test_pin_and_stop_round_trip(server):
    _, session, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    resp = await c.call("session.pin", lat=37.7749, lon=-122.4194)
    assert resp["ok"] and resp["result"]["mode"] == "pinned"
    resp = await c.call("session.stop")
    assert resp["ok"] and resp["result"]["mode"] == "idle"
    await c.close()


@pytest.mark.asyncio
async def test_rejects_out_of_range_coordinates(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    resp = await c.call("session.pin", lat=91.0, lon=0.0)
    assert not resp["ok"] and "out of range" in resp["error"]
    await c.close()


@pytest.mark.asyncio
async def test_unknown_method_is_an_error_not_a_crash(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    resp = await c.call("session.nuke")
    assert not resp["ok"] and "unknown method" in resp["error"]
    resp = await c.call("status")
    assert resp["ok"]  # connection survived
    await c.close()


@pytest.mark.asyncio
async def test_drive_returns_plan_summary(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    pts = [[37.7749 + i * 0.0005, -122.4194] for i in range(20)]
    resp = await c.call("session.drive", points=pts, expected_travel_time=300.0)
    assert resp["ok"]
    assert resp["result"]["eta_achievable"] is True
    assert resp["result"]["total_time"] == pytest.approx(300.0, rel=0.05)
    assert resp["result"]["distance"] > 500
    await c.call("session.stop")
    await c.close()


@pytest.mark.asyncio
async def test_impossible_eta_is_reported_to_the_ui(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    pts = [[37.7749 + i * 0.0005, -122.4194] for i in range(20)]
    resp = await c.call("session.drive", points=pts, expected_travel_time=2.0)
    assert resp["ok"]
    assert resp["result"]["eta_achievable"] is False
    assert resp["result"]["total_time"] > 2.0
    await c.call("session.stop")
    await c.close()


@pytest.mark.asyncio
async def test_rejects_single_point_route(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    resp = await c.call("session.drive", points=[[1.0, 2.0]])
    assert not resp["ok"]
    await c.close()


@pytest.mark.asyncio
async def test_socket_path_guards_sun_path_limit(monkeypatch):
    """A home directory deep enough to overflow sockaddr_un must fail loudly."""
    from mirage import security
    monkeypatch.setenv("MIRAGE_STATE_DIR", "/tmp/" + "d" * 120)
    with pytest.raises(RuntimeError, match="AF_UNIX limit"):
        security.socket_path()


# --------------------------------------------------------------- consent gate

@pytest.mark.asyncio
async def test_pin_refused_without_consent():
    tmp = tempfile.mkdtemp(prefix="mrg", dir="/tmp")
    srv, session, sock = _make_server(tmp, consent=False)
    await srv.start()
    serving = asyncio.create_task(srv.serve_forever())
    try:
        c = Client(*await asyncio.open_unix_connection(str(sock)))
        resp = await c.call("session.pin", lat=37.7749, lon=-122.4194)
        assert not resp["ok"]
        assert "No consent" in resp["error"]
        assert resp.get("remedy")
        await c.close()
    finally:
        serving.cancel()
        await session.close()
        await srv.close()
        shutil.rmtree(tmp, ignore_errors=True)


@pytest.mark.asyncio
async def test_managed_device_refused_even_with_consent_on_file():
    """The eligibility check outranks consent — a supervised phone is someone else's
    to set policy on, whatever this Mac's owner agreed to."""
    tmp = tempfile.mkdtemp(prefix="mrg", dir="/tmp")
    srv, session, sock = _make_server(
        tmp, consent=True, eligibility=Eligibility(supervised=True, checked=True))
    await srv.start()
    serving = asyncio.create_task(srv.serve_forever())
    try:
        c = Client(*await asyncio.open_unix_connection(str(sock)))
        resp = await c.call("session.pin", lat=37.7749, lon=-122.4194)
        assert not resp["ok"]
        assert "managed" in resp["error"].lower()
        resp = await c.call("session.drive", points=[[1.0, 2.0], [1.001, 2.0]])
        assert not resp["ok"]
        await c.close()
    finally:
        serving.cancel()
        await session.close()
        await srv.close()
        shutil.rmtree(tmp, ignore_errors=True)


@pytest.mark.asyncio
async def test_drive_refused_when_only_pin_is_allowed():
    tmp = tempfile.mkdtemp(prefix="mrg", dir="/tmp")
    srv, session, sock = _make_server(
        tmp, grants=Grants(allow_pin=True, allow_drive=False))
    await srv.start()
    serving = asyncio.create_task(srv.serve_forever())
    try:
        c = Client(*await asyncio.open_unix_connection(str(sock)))
        assert (await c.call("session.pin", lat=1.0, lon=2.0))["ok"]
        pts = [[37.7749 + i * 0.0005, -122.4194] for i in range(10)]
        resp = await c.call("session.drive", points=pts, expected_travel_time=300.0)
        assert not resp["ok"]
        assert "not allowed drive" in resp["error"]
        await c.call("session.stop")
        await c.close()
    finally:
        serving.cancel()
        await session.close()
        await srv.close()
        shutil.rmtree(tmp, ignore_errors=True)


@pytest.mark.asyncio
async def test_consent_status_reports_eligibility(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    resp = await c.call("consent.status")
    assert resp["ok"]
    assert resp["result"]["granted"] is True
    assert resp["result"]["eligibility"]["ok"] is True
    await c.close()


@pytest.mark.asyncio
async def test_revoking_consent_stops_an_active_session(server):
    _, session, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    assert (await c.call("session.pin", lat=1.0, lon=2.0))["ok"]
    assert (await c.call("consent.revoke"))["ok"]
    assert session.state.mode.value == "idle"
    resp = await c.call("session.pin", lat=1.0, lon=2.0)
    assert not resp["ok"]
    await c.close()


@pytest.mark.asyncio
async def test_drive_accepts_waypoint_stops(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    pts = [[37.7749 + i * 0.0005, -122.4194] for i in range(20)]
    resp = await c.call("session.drive", points=pts, expected_travel_time=300.0,
                        stops=[{"index": 10, "seconds": 120}])
    assert resp["ok"]
    assert resp["result"]["stop_seconds"] == 120
    assert resp["result"]["total_time"] > 300.0
    await c.call("session.stop")
    await c.close()


@pytest.mark.asyncio
async def test_absurd_stop_duration_is_refused(server):
    _, _, sock = server
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    pts = [[37.7749 + i * 0.0005, -122.4194] for i in range(10)]
    resp = await c.call("session.drive", points=pts,
                        stops=[{"index": 5, "seconds": 999999}])
    assert not resp["ok"]
    assert "out of range" in resp["error"]
    await c.close()


# ------------------------------------------------------ restoring real location

@pytest.mark.asyncio
async def test_restore_works_without_consent():
    """Putting the location back must never be refused. A grant that expired mid-session
    would otherwise strand the user on a false location."""
    tmp = tempfile.mkdtemp(prefix="mrg", dir="/tmp")
    srv, session, sock = _make_server(tmp, consent=False)
    await srv.start()
    serving = asyncio.create_task(srv.serve_forever())
    try:
        c = Client(*await asyncio.open_unix_connection(str(sock)))
        assert not (await c.call("session.pin", lat=1.0, lon=2.0))["ok"]   # gated
        resp = await c.call("session.restore")                            # not gated
        assert resp["ok"]
        assert resp["result"]["mode"] == "idle"
        await c.close()
    finally:
        serving.cancel()
        await session.close()
        await srv.close()
        shutil.rmtree(tmp, ignore_errors=True)


@pytest.mark.asyncio
async def test_restore_works_on_a_managed_device(server):
    """Eligibility blocks changing location, never putting it back."""
    tmp = tempfile.mkdtemp(prefix="mrg", dir="/tmp")
    from mirage.consent import Eligibility
    srv, session, sock = _make_server(tmp, eligibility=Eligibility(supervised=True, checked=True))
    await srv.start()
    serving = asyncio.create_task(srv.serve_forever())
    try:
        c = Client(*await asyncio.open_unix_connection(str(sock)))
        assert (await c.call("session.restore"))["ok"]
        await c.close()
    finally:
        serving.cancel()
        await session.close()
        await srv.close()
        shutil.rmtree(tmp, ignore_errors=True)


@pytest.mark.asyncio
async def test_restore_clears_the_device_even_when_idle(server):
    """The crash case: the engine believes it is idle, but the device is still
    simulating from a run that died. Restore must clear regardless."""
    _, session, sock = server
    injector = session._injector
    before = injector.cleared
    c = Client(*await asyncio.open_unix_connection(str(sock)))
    assert session.state.mode.value == "idle"
    assert (await c.call("session.restore"))["ok"]
    assert injector.cleared > before
    await c.close()
