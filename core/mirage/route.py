"""Trajectory planning: turn a route polyline plus a traffic-aware ETA into a
physically plausible sequence of timed positions.

The naive approach — constant speed = distance / ETA — is what makes simulated
drives look fake. It sends you through hairpins and motorways at the same 47 km/h
and never stops at a junction.

Instead we run the standard three-stage time-parameterisation used by motion
planners:

  1. Cap speed at each vertex by the local turn radius (lateral acceleration limit),
     so the vehicle slows for corners.
  2. Forward pass bounding longitudinal acceleration, backward pass bounding
     braking, so speed changes are reachable.
  3. Insert dwell time at junctions, then scale the whole profile so total elapsed
     time equals the ETA that Apple gave us.

Step 3 is where traffic enters, and it is why this stays honest without a separate
traffic feed: `MKDirections` already returns a *traffic-aware* `expectedTravelTime`.
If Apple says a 10 km trip takes 30 minutes because the motorway is jammed, scaling
the free-flow profile to hit 30 minutes slows every segment proportionally. Congestion
shows up as a uniformly slower drive, which is what congestion looks like.
"""
from __future__ import annotations

import bisect
import math
from dataclasses import dataclass, field

from .geo import LatLon, Polyline, turn_angle


@dataclass(frozen=True, slots=True)
class VehicleLimits:
    v_max: float = 33.3      # m/s, ~120 km/h
    a_accel: float = 1.8     # m/s^2, comfortable
    a_brake: float = 3.0     # m/s^2
    a_lateral: float = 2.5   # m/s^2 cornering comfort
    v_min_corner: float = 2.0

    # Junction dwell modelling
    stop_turn_threshold: float = 55.0   # degrees of heading change that implies a junction
    stop_probability: float = 0.45      # fraction of such junctions where we actually stop
    stop_duration: float = 9.0          # seconds, averaged over lights and give-ways

    # How far above a posted limit a driver actually travels when traffic allows. Driving
    # a route at exactly the limit the whole way is its own kind of tell; nobody does it.
    # Scaled down as congestion rises - you cannot speed in a queue.
    speeding_allowance: float = 8.0 / 3.6   # m/s, about 8 km/h


@dataclass
class DrivePlan:
    """A fully timed trajectory. `state_at(t)` is the only thing playback needs."""

    polyline: Polyline
    speeds: list[float]        # m/s at each vertex
    arrive: list[float]        # seconds, arrival time at each vertex
    depart: list[float]        # seconds, departure (arrive + any dwell)
    limits: VehicleLimits = field(default_factory=VehicleLimits)
    requested_eta: float | None = None
    eta_achievable: bool = True
    """False when the requested ETA was faster than the route can physically be
    driven; `total_time` is then the achievable time, not the requested one."""

    @property
    def total_time(self) -> float:
        return self.depart[-1]

    @property
    def distance(self) -> float:
        return self.polyline.length

    def state_at(self, t: float) -> tuple[LatLon, float, float]:
        """Position, heading (deg) and speed (m/s) at `t` seconds into the drive."""
        if t <= 0 or t >= self.total_time:
            s = 0.0 if t <= 0 else self.polyline.length
            p, h = self.polyline.point_at(s)
            return p, h, 0.0

        # depart[] is monotonic, so this is the vertex we most recently left.
        i = bisect.bisect_right(self.depart, t) - 1
        if i < 0:  # still dwelling at the start vertex
            p, h = self.polyline.point_at(0.0)
            return p, h, 0.0
        if i >= len(self.speeds) - 1:
            p, h = self.polyline.point_at(self.polyline.length)
            return p, h, 0.0

        # t in [depart[i], depart[i+1]) splits into travelling, then dwelling at i+1.
        if t >= self.arrive[i + 1]:
            p, h = self.polyline.point_at(self.polyline.cumulative[i + 1])
            return p, h, 0.0

        span = self.arrive[i + 1] - self.depart[i]
        v0, v1 = self.speeds[i], self.speeds[i + 1]
        if span <= 0:
            p, h = self.polyline.point_at(self.polyline.cumulative[i])
            return p, h, v0
        tau = min(t - self.depart[i], span)
        accel = (v1 - v0) / span
        s = self.polyline.cumulative[i] + v0 * tau + 0.5 * accel * tau * tau
        p, h = self.polyline.point_at(s)
        return p, h, max(0.0, v0 + accel * tau)


def _ceilings(poly: Polyline, limits: VehicleLimits,
              road_limits: list[float] | None, allowance: float = 0.0) -> list[float]:
    """The hard speed ceiling at each vertex: the vehicle's, capped by the road's.

    Without `road_limits` every vertex is capped at `v_max`, which on a residential street
    means the solver will happily do 120 km/h because nothing tells it not to. That is a
    far louder tell than any amount of traffic modelling fixes.
    """
    out = []
    for i in range(len(poly)):
        ceiling = limits.v_max
        if road_limits is not None and i < len(road_limits):
            limit = road_limits[i]
            if limit and limit > 0:
                # The allowance applies only where a limit is actually known. With no
                # limit there is nothing to be over, and v_max already caps things.
                ceiling = min(ceiling, float(limit) + allowance)
        out.append(ceiling)
    return out


def _corner_speeds(poly: Polyline, limits: VehicleLimits,
                   ceilings: list[float] | None = None) -> list[float]:
    """v = sqrt(a_lat * R) — the speed at which cornering hits the comfort limit,
    then capped by whatever the road allows."""
    radii = poly.curvature_radii()
    caps = ceilings or [limits.v_max] * len(poly)
    speeds = []
    for i, r in enumerate(radii):
        cap = caps[i]
        if math.isinf(r):
            speeds.append(cap)
        else:
            speeds.append(min(cap, max(limits.v_min_corner, math.sqrt(limits.a_lateral * r))))
    speeds[0] = 0.0
    speeds[-1] = 0.0
    return speeds


def _junction_dwells(poly: Polyline, limits: VehicleLimits, rng) -> list[float]:
    """Seconds spent stationary at each vertex. Sharp heading changes imply a
    junction; we stop at a fraction of them, deterministically per-seed."""
    dwell = [0.0] * len(poly)
    for i in range(1, len(poly) - 1):
        if turn_angle(poly.points[i - 1], poly.points[i], poly.points[i + 1]) >= limits.stop_turn_threshold:
            if rng.random() < limits.stop_probability:
                dwell[i] = limits.stop_duration * rng.uniform(0.5, 1.8)
    return dwell


def _apply_accel_limits(speeds: list[float], seg: list[float], limits: VehicleLimits) -> None:
    """Forward pass for acceleration, backward for braking. In place."""
    for i in range(len(seg)):
        reachable = math.sqrt(speeds[i] ** 2 + 2 * limits.a_accel * seg[i])
        speeds[i + 1] = min(speeds[i + 1], reachable)
    for i in range(len(seg) - 1, -1, -1):
        stoppable = math.sqrt(speeds[i + 1] ** 2 + 2 * limits.a_brake * seg[i])
        speeds[i] = min(speeds[i], stoppable)


def _segment_times(speeds: list[float], seg: list[float]) -> list[float]:
    """Trapezoidal: dt = 2*ds/(v0+v1), exact for constant acceleration."""
    out = []
    for i, ds in enumerate(seg):
        vsum = speeds[i] + speeds[i + 1]
        out.append((2.0 * ds / vsum) if vsum > 1e-6 else 0.0)
    return out


def build_plan(
    poly: Polyline,
    expected_travel_time: float | None = None,
    limits: VehicleLimits | None = None,
    seed: int = 0,
    include_stops: bool = True,
    waypoint_stops: dict[int, float] | None = None,
    road_limits: list[float] | None = None,
) -> DrivePlan:
    """Build a timed trajectory along `poly`.

    :param expected_travel_time: traffic-aware driving time in seconds, from
        MKDirections. The free-flow profile is scaled so the *driving* portion takes
        exactly this long.
    :param road_limits: per-vertex speed ceiling in m/s, from OpenStreetMap's `maxspeed`
        tags. Anything falsy or non-positive means "no limit known here", and that vertex
        falls back to the vehicle ceiling.
    :param waypoint_stops: vertex index → seconds to wait there. These are the user's
        own chosen stops on a multi-leg trip, so they are **added on top** of the
        estimate rather than scaled into it: Apple's number is how long the driving
        takes, and it cannot know you intend to spend ten minutes at the second pin.
    """
    import random

    limits = limits or VehicleLimits()
    rng = random.Random(seed)
    seg = poly.segment_lengths()

    def solve(allowance: float):
        caps = _ceilings(poly, limits, road_limits, allowance)
        v = _corner_speeds(poly, limits, caps)
        _apply_accel_limits(v, seg, limits)
        return caps, v

    # First pass assumes traffic allows the full allowance.
    ceilings, speeds = solve(limits.speeding_allowance)

    # Then let the traffic-aware estimate say otherwise. A requested time close to the
    # free-flow time means the road is clear and drivers sit above the limit; one much
    # longer means a queue, where nobody is. Apple gives one number for the whole route,
    # so this is necessarily a route-wide judgement - it is the only traffic signal
    # available without a paid per-segment feed.
    if road_limits and expected_travel_time and expected_travel_time > 0:
        free_flow = sum(_segment_times(speeds, seg))
        if free_flow > 0:
            congestion = expected_travel_time / free_flow
            factor = max(0.0, min(1.0, 2.0 - congestion))
            if factor < 1.0:
                ceilings, speeds = solve(limits.speeding_allowance * factor)

    dwell = _junction_dwells(poly, limits, rng) if include_stops else [0.0] * len(poly)
    junction_total = sum(dwell)

    # The user's own stops, kept separate from the modelled junction dwells because they
    # are accounted for differently against the estimate below.
    explicit = [0.0] * len(poly)
    for index, seconds in (waypoint_stops or {}).items():
        if 0 <= int(index) < len(poly) and seconds > 0:
            explicit[int(index)] += float(seconds)
    explicit_total = sum(explicit)

    # A stop means zero speed at that vertex; re-run the limits so we actually
    # brake into it and accelerate out rather than teleporting to a halt.
    if any(d > 0 for d in dwell) or explicit_total > 0:
        for i in range(len(poly)):
            if dwell[i] > 0 or explicit[i] > 0:
                speeds[i] = 0.0
        speeds[0] = speeds[-1] = 0.0
        _apply_accel_limits(speeds, seg, limits)

    times = _segment_times(speeds, seg)
    moving = sum(times)
    stopped = junction_total

    if expected_travel_time and expected_travel_time > 0 and moving > 0:
        target_moving = expected_travel_time - stopped
        if target_moving < moving * 0.25:
            # The estimate is shorter than the modelled junction dwells allow. Drop
            # those and keep the estimate, which is the number the user cares about.
            # Explicit waypoint stops are never dropped: the user asked for them.
            dwell = [0.0] * len(poly)
            stopped = 0.0
            target_moving = expected_travel_time
        scale = moving / target_moving
        speeds = [v * scale for v in speeds]
        if scale > 1.0:
            # The ETA is faster than free flow. Honour physics over the ETA: clamp to
            # the speed ceiling and re-solve the acceleration limits, then report that
            # the requested time was not achievable. Silently emitting 1200 km/h would
            # be a far louder tell than arriving late.
            # Clamp to the road's ceiling, not just the vehicle's: an optimistic
            # estimate must not turn into 120 km/h down a residential street.
            speeds = [min(v, ceilings[i]) for i, v in enumerate(speeds)]
            speeds[0] = speeds[-1] = 0.0
            _apply_accel_limits(speeds, seg, limits)
        times = _segment_times(speeds, seg)

    # Achievability is judged on the driving portion only; a long deliberate stop does
    # not make an estimate "unachievable".
    achieved = sum(times) + sum(dwell)
    total_dwell = [dwell[i] + explicit[i] for i in range(len(poly))]

    arrive, depart = [0.0], [total_dwell[0]]
    for i, dt in enumerate(times):
        a = depart[i] + dt
        arrive.append(a)
        depart.append(a + total_dwell[i + 1])

    return DrivePlan(
        polyline=poly,
        speeds=speeds,
        arrive=arrive,
        depart=depart,
        limits=limits,
        requested_eta=expected_travel_time,
        eta_achievable=(
            expected_travel_time is None
            or achieved <= expected_travel_time * 1.05
        ),
    )
