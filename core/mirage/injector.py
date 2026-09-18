"""The actual location override.

`LocationSimulation` speaks the ``com.apple.instruments.server.services.LocationSimulation``
DTX channel. On iOS 17+ that arrives over an RSD tunnel; on older devices over lockdown.
`DvtProvider` picks the right transport, so this module does not care which.

The channel is opened once and held for the life of the session. Reopening it per fix
would add hundreds of milliseconds of setup to every tick and makes a 1 Hz drive
impossible.
"""
from __future__ import annotations

import logging
from contextlib import AsyncExitStack
from typing import Protocol

log = logging.getLogger(__name__)


class Injector(Protocol):
    async def open(self) -> None: ...
    async def set(self, lat: float, lon: float) -> None: ...
    async def clear(self) -> None: ...
    async def close(self) -> None: ...


class DvtInjector:
    """Holds the DVT location-simulation channel open against a connected device."""

    def __init__(self, service_provider) -> None:
        self._provider = service_provider
        self._stack: AsyncExitStack | None = None
        self._sim = None

    async def open(self, force: bool = False) -> None:
        if self._sim is not None and not force:
            return
        if force:
            await self.close()
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

        stack = AsyncExitStack()
        try:
            dvt = await stack.enter_async_context(DvtProvider(self._provider))
            self._sim = await stack.enter_async_context(LocationSimulation(dvt))
        except Exception:
            await stack.aclose()
            raise
        self._stack = stack
        log.info("DVT location simulation channel open")

    async def set(self, lat: float, lon: float) -> None:
        if self._sim is None:
            raise RuntimeError("injector not open")
        await self._sim.set(lat, lon)

    async def clear(self) -> None:
        if self._sim is not None:
            await self._sim.clear()

    async def close(self) -> None:
        if self._stack is None:
            return
        try:
            await self.clear()
        except Exception as exc:  # noqa: BLE001
            log.warning("could not clear location on close: %s", exc)
        finally:
            await self._stack.aclose()
            self._stack = None
            self._sim = None


class MockInjector:
    """Records fixes instead of sending them. Lets the whole engine — session,
    trajectory, jitter, RPC — be tested end to end with no iPhone attached."""

    def __init__(self) -> None:
        self.fixes: list[tuple[float, float]] = []
        self.cleared = 0
        self.opened = False

    async def open(self) -> None:
        self.opened = True

    async def set(self, lat: float, lon: float) -> None:
        self.fixes.append((lat, lon))

    async def clear(self) -> None:
        self.cleared += 1

    async def close(self) -> None:
        await self.clear()
        self.opened = False


class DisconnectedInjector:
    """Stands in when no device is attached.

    The engine must be able to serve without an iPhone present — otherwise the app
    cannot show its own setup screen, which is exactly the state a first-time user is
    in. Any attempt to actually move a location fails loudly instead of silently
    pretending to work.
    """

    def __init__(self, reason: str, remedy: str = "") -> None:
        self.reason = reason
        self.remedy = remedy or "Connect an iPhone and enable Developer Mode."

    def _fail(self):
        from .device import PreflightError

        raise PreflightError(self.reason, self.remedy)

    async def open(self) -> None:
        self._fail()

    async def set(self, lat: float, lon: float) -> None:
        self._fail()

    async def clear(self) -> None:
        return None          # nothing to clear; never raise on a restore path

    async def close(self) -> None:
        return None
