"""Headless entry point. The SwiftUI app spawns `mirage serve`; everything the UI can
do is reachable here first, so the engine is usable and debuggable without it."""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import signal
import sys

from .consent import ConsentStore, Eligibility, check_eligibility
from .device import PreflightError, connect, list_devices
from .injector import DisconnectedInjector, DvtInjector, MockInjector
from .rpc import RpcServer
from .security import socket_path
from .session import Session


def _log(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )


async def _build_session(mock: bool) -> tuple[Session, Eligibility]:
    """Returns the session and what the device says about who manages it."""
    if mock:
        return Session(MockInjector(), udid="mock-device"), Eligibility(checked=True)
    conn = await connect()
    eligibility = await check_eligibility(conn.rsd)
    for reason in eligibility.blocking_reasons:
        logging.getLogger(__name__).warning("device ineligible: %s", reason)
    logging.getLogger(__name__).info("connected over the %s transport", conn.transport)

    held = {"conn": conn}

    async def reconnect() -> DvtInjector:
        """Open a fresh tunnel and channel.

        Called when the existing channel is dead — typically because the iPhone was
        unplugged or left the network. Succeeds only if the device is reachable again.
        """
        with contextlib.suppress(Exception):
            await held["conn"].aclose()
        fresh = await connect()
        held["conn"] = fresh
        logging.getLogger(__name__).info("reconnected over the %s transport", fresh.transport)
        return DvtInjector(fresh.rsd)

    return Session(DvtInjector(conn.rsd), udid=conn.udid, reconnect=reconnect), eligibility


async def cmd_serve(args) -> int:
    # Serving must not depend on a device being present: the app needs the control
    # socket up in order to show setup, and setup is where the user is told to plug
    # the phone in.
    try:
        session, eligibility = await _build_session(args.mock)
    except PreflightError as exc:
        logging.getLogger(__name__).warning("starting without a device: %s", exc)
        session = Session(DisconnectedInjector(str(exc), exc.remedy))
        eligibility = Eligibility(checked=False, check_error=str(exc))

    # Deliberately does NOT clear on startup.
    #
    # A simulated location survives the app closing, the cable being unplugged, and the
    # engine dying — the override lives in locationd, and nothing revokes it until a
    # stop is sent or the phone reboots. That persistence is a feature: it is what lets
    # someone set a location and then walk away from the Mac.
    #
    # So Mirage never silently undoes it. The app detects that the previous run ended
    # mid-simulation and offers the choice; taking it away automatically would be
    # surprising in the one direction users cannot undo.

    server = RpcServer(session, consent=ConsentStore(), eligibility=eligibility)
    await server.start()
    # Machine-readable handshake so the app can detect readiness without polling the
    # socket path or scraping the log format.
    print(f"MIRAGE_READY {server.path}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)

    serving = asyncio.create_task(server.serve_forever())
    try:
        await stop.wait()
    finally:
        # The safety invariant: never leave the device simulating.
        print("\nshutting down, restoring real location...", file=sys.stderr)
        serving.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await serving
        with contextlib.suppress(Exception):
            await session.close()
        await server.close()
    return 0


async def cmd_devices(_args) -> int:
    for d in await list_devices():
        flag = "tunnel ready" if d.tunnel_ready else "NO TUNNEL"
        print(f"{d.udid}  {d.connection:<8} {flag}")
    return 0


async def cmd_eligibility(args) -> int:
    """Report whether the connected device is managed by someone else."""
    _, eligibility = await _build_session(args.mock)
    print(json.dumps(eligibility.to_json(), indent=2))
    return 0 if eligibility.ok else 1


async def cmd_pin(args) -> int:
    session, _ = await _build_session(args.mock)
    try:
        await session.pin(args.lat, args.lon, profile=args.profile)
        print(f"pinned to {args.lat}, {args.lon} — ctrl-c to restore real location")
        await asyncio.Event().wait()
    finally:
        with contextlib.suppress(Exception):
            await session.stop()
        await session.close()
    return 0


async def cmd_drive(args) -> int:
    data = json.load(args.route)
    points = data["points"] if isinstance(data, dict) else data
    eta = data.get("expected_travel_time") if isinstance(data, dict) else None
    session, _ = await _build_session(args.mock)
    try:
        plan = await session.drive(points, expected_travel_time=eta)
        print(f"driving {plan.distance / 1000:.1f} km over {plan.total_time / 60:.1f} min")
        while session.state.mode.value == "driving":
            s = session.state
            where = f"{s.lat:.5f},{s.lon:.5f}" if s.lat is not None else "waiting for first fix"
            print(
                f"\r  {s.progress * 100:5.1f}%  {s.speed * 3.6:5.1f} km/h  "
                f"ETA {s.eta_remaining / 60:4.1f} min  {where}   ",
                end="",
                flush=True,
            )
            await asyncio.sleep(0.5)
        print("\narrived")
    finally:
        with contextlib.suppress(Exception):
            await session.stop()
        await session.close()
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="mirage", description="Mirage location engine")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--mock", action="store_true", help="run without a device (records fixes)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("serve", help=f"run the control server on {socket_path()}")
    sub.add_parser("devices", help="list connected devices and tunnel status")
    sub.add_parser("eligibility", help="report whether the device is supervised or managed")

    sp = sub.add_parser("pin", help="hold a fixed location")
    sp.add_argument("lat", type=float)
    sp.add_argument("lon", type=float)
    sp.add_argument("--profile", default="stationary", choices=["stationary", "walking", "driving", "indoors"])

    sd = sub.add_parser("drive", help="play a route from a JSON file")
    sd.add_argument("route", type=argparse.FileType("r"))

    args = p.parse_args(argv)
    _log(args.verbose)

    handlers = {
        "serve": cmd_serve,
        "devices": cmd_devices,
        "eligibility": cmd_eligibility,
        "pin": cmd_pin,
        "drive": cmd_drive,
    }
    try:
        return asyncio.run(handlers[args.cmd](args))
    except PreflightError as exc:
        print(f"\n{exc}\n\n{exc.remedy}\n", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
