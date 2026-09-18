"""Positional noise.

IMPORTANT: the DVT selector is ``simulateLocationWithLatitude:longitude:`` — latitude
and longitude and nothing else. We cannot inject speed, course, altitude or horizontal
accuracy; iOS derives all of those itself from successive fixes. The *only* realism
lever we have is the sequence of coordinates and the timing between them. That is why
this module and `route.py` carry most of the weight of the product.

A perfectly static coordinate is the single loudest tell that a location is simulated:
real GNSS never stops moving. But real drift is not white noise either — it is strongly
autocorrelated, wandering over tens of seconds as the satellite geometry and multipath
environment change. An Ornstein-Uhlenbeck process reproduces that: mean-reverting, so it
stays near the true position, but temporally smooth rather than jumping every fix.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass

from .geo import LatLon, destination


@dataclass(frozen=True, slots=True)
class JitterProfile:
    """`sigma` is the stationary standard deviation in metres; `tau` the correlation
    time in seconds (how long the wander takes to forget where it was)."""

    sigma: float
    tau: float

    @property
    def theta(self) -> float:
        return 1.0 / self.tau


# Tuned to what a phone actually reports: worse when stationary indoors (multipath,
# no Doppler aiding), better at speed with clear sky.
STATIONARY = JitterProfile(sigma=4.5, tau=30.0)
WALKING = JitterProfile(sigma=5.0, tau=15.0)
DRIVING = JitterProfile(sigma=3.0, tau=10.0)
PARKED_INDOORS = JitterProfile(sigma=12.0, tau=45.0)

PROFILES = {
    "stationary": STATIONARY,
    "walking": WALKING,
    "driving": DRIVING,
    "indoors": PARKED_INDOORS,
}


class OrnsteinUhlenbeck2D:
    """Mean-reverting 2D random walk: dX = -theta*X*dt + sigma_w*dW.

    Parameterised by the *stationary* std the caller wants, rather than the raw
    volatility, because that is the number with a physical meaning here.
    """

    def __init__(self, profile: JitterProfile, rng: random.Random | None = None) -> None:
        self.profile = profile
        self._rng = rng or random.Random()
        self._x = 0.0
        self._y = 0.0

    def step(self, dt: float) -> tuple[float, float]:
        """Advance by `dt` seconds; returns (east, north) offset in metres.

        Uses the exact discrete-time solution of the OU SDE rather than an Euler
        step, so the statistics stay correct for any dt — including the long dt of
        a resumed session.
        """
        theta, sigma = self.profile.theta, self.profile.sigma
        decay = math.exp(-theta * dt)
        # Stationary std of the increment given the decay.
        noise_std = sigma * math.sqrt(max(0.0, 1.0 - decay * decay))
        self._x = self._x * decay + self._rng.gauss(0.0, noise_std)
        self._y = self._y * decay + self._rng.gauss(0.0, noise_std)
        return self._x, self._y

    def apply(self, point: LatLon, dt: float) -> LatLon:
        east, north = self.step(dt)
        dist = math.hypot(east, north)
        if dist < 1e-6:
            return point
        return destination(point, math.degrees(math.atan2(east, north)) % 360.0, dist)
