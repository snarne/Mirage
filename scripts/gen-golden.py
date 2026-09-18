#!/usr/bin/env python3
"""Regenerate the cross-engine golden values.

The Python engine in `core/mirage/` is the reference implementation: it drives the Mac
app and is covered by the Python suite. `ui/Sources/MirageKit/{Geo,Motion,Route}.swift`
is a port of it for the iPhone app, and `ui/Tests/MirageKitTests/GoldenTests.swift`
asserts the port against the numbers this script produces.

Run it after any deliberate change to the Python maths, and expect the Swift suite to
fail until the port is brought back into line. That failure is the point.

    ./scripts/gen-golden.py

Writes ui/Tests/MirageKitTests/Resources/golden.json.
"""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "core"))

from mirage.geo import (  # noqa: E402
    LatLon, Polyline, bearing, circumradius, destination, haversine, turn_angle,
)
from mirage.motion import JitterProfile, OrnsteinUhlenbeck2D  # noqa: E402
from mirage.route import VehicleLimits, build_plan  # noqa: E402

OUT = ROOT / "ui" / "Tests" / "MirageKitTests" / "Resources" / "golden.json"

R = lambda x: round(x, 9)  # noqa: E731

# A short Bristol route with a couple of real turns in it.
PTS = [
    (51.4490, -2.6000),
    (51.4490, -2.5900),
    (51.4520, -2.5850),
    (51.4560, -2.5845),
    (51.4600, -2.5800),
    (51.4600, -2.5700),
    (51.4640, -2.5650),
]

# The RNG is replaced by a fixed sequence wherever noise is involved, so the decay maths
# is compared rather than Python's Mersenne Twister — which the Swift port deliberately
# does not reproduce.
SEQ = [0.4, -1.2, 0.85, 0.05, -0.3, 1.7, -0.9, 0.22, 0.61, -1.45]


class FixedRNG:
    def __init__(self, seq):
        self.seq = list(seq)
        self.i = 0

    def gauss(self, mu, sigma):
        v = self.seq[self.i % len(self.seq)]
        self.i += 1
        return mu + sigma * v


def build():
    out = {}

    a, b = LatLon(51.4545, -2.5879), LatLon(51.4816, -2.2931)
    c = LatLon(*PTS[0])

    out["haversine"] = [
        {"a": [a.lat, a.lon], "b": [b.lat, b.lon], "m": R(haversine(a, b))},
        {"a": [a.lat, a.lon], "b": [a.lat, a.lon], "m": R(haversine(a, a))},
        {"a": [0.0, 0.0], "b": [0.0, 1.0], "m": R(haversine(LatLon(0, 0), LatLon(0, 1)))},
        {"a": [c.lat, c.lon], "b": [b.lat, b.lon], "m": R(haversine(c, b))},
    ]
    out["bearing"] = [
        {"a": [a.lat, a.lon], "b": [b.lat, b.lon], "deg": R(bearing(a, b))},
        {"a": [0.0, 0.0], "b": [1.0, 0.0], "deg": R(bearing(LatLon(0, 0), LatLon(1, 0)))},
        {"a": [0.0, 0.0], "b": [0.0, -1.0], "deg": R(bearing(LatLon(0, 0), LatLon(0, -1)))},
        {"a": [c.lat, c.lon], "b": [a.lat, a.lon], "deg": R(bearing(c, a))},
    ]
    out["destination"] = []
    for brg, dist in [(45.0, 1000.0), (0.0, 5000.0), (180.0, 250.0), (271.3, 12345.0)]:
        d = destination(a, brg, dist)
        out["destination"].append(
            {"from": [a.lat, a.lon], "bearing": brg, "m": dist, "to": [R(d.lat), R(d.lon)]}
        )

    p0, p1, p2 = LatLon(*PTS[1]), LatLon(*PTS[2]), LatLon(*PTS[3])
    cr = circumradius(p0, p1, p2)
    out["circumradius"] = [
        {"p": [list(PTS[1]), list(PTS[2]), list(PTS[3])],
         "r": R(cr) if math.isfinite(cr) else "inf"},
        {"p": [[0.0, 0.0], [0.0, 0.1], [0.0, 0.2]], "r": "inf"},
    ]
    out["turn_angle"] = [
        {"p": [list(PTS[1]), list(PTS[2]), list(PTS[3])], "deg": R(turn_angle(p0, p1, p2))},
        {"p": [list(PTS[3]), list(PTS[4]), list(PTS[5])],
         "deg": R(turn_angle(LatLon(*PTS[3]), LatLon(*PTS[4]), LatLon(*PTS[5])))},
    ]

    poly = Polyline([LatLon(lat, lon) for lat, lon in PTS])
    out["polyline"] = {
        "points": [list(p) for p in PTS],
        "length": R(poly.length),
        "segment_lengths": [R(x) for x in poly.segment_lengths()],
        "curvature_radii": [("inf" if math.isinf(r) else R(r)) for r in poly.curvature_radii()],
        "point_at": [],
    }
    for s in [0.0, 1.0, 250.0, 700.0, 1500.0, poly.length * 0.5,
              poly.length, poly.length + 500.0, -10.0]:
        pt, hdg = poly.point_at(s)
        out["polyline"]["point_at"].append(
            {"s": R(s), "lat": R(pt.lat), "lon": R(pt.lon), "heading": R(hdg)}
        )

    out["ou"] = []
    for name, prof in [("stationary", JitterProfile(4.5, 30.0)),
                       ("driving", JitterProfile(3.0, 10.0)),
                       ("indoors", JitterProfile(12.0, 45.0))]:
        ou = OrnsteinUhlenbeck2D(prof, rng=FixedRNG(SEQ))
        steps = []
        for dt in [1.0, 1.0, 1.0, 5.0, 0.5, 60.0]:
            x, y = ou.step(dt)
            steps.append({"dt": dt, "east": R(x), "north": R(y)})
        out["ou"].append({"profile": name, "sigma": prof.sigma, "tau": prof.tau,
                          "unit_normals": SEQ, "steps": steps})

    ou = OrnsteinUhlenbeck2D(JitterProfile(4.5, 30.0), rng=FixedRNG(SEQ))
    applied = []
    for dt in [1.0, 2.0, 30.0]:
        q = ou.apply(LatLon(51.4545, -2.5879), dt)
        applied.append({"dt": dt, "lat": R(q.lat), "lon": R(q.lon)})
    out["ou_apply"] = {"sigma": 4.5, "tau": 30.0, "unit_normals": SEQ,
                       "origin": [51.4545, -2.5879], "steps": applied}

    lim = VehicleLimits()
    out["limits"] = {"v_max": lim.v_max, "a_accel": lim.a_accel, "a_brake": lim.a_brake,
                     "a_lateral": lim.a_lateral, "v_min_corner": lim.v_min_corner}

    # include_stops=False throughout: the junction model is the one deliberately
    # non-portable piece. Everything else is exactly reproducible in any language.
    # 50, 50, 30, 30, 90, 90, 50 km/h in m/s: a residential stretch in the middle of
    # faster roads, which is exactly the case a single global v_max gets wrong.
    ROAD_LIMITS = [13.889, 13.889, 8.333, 8.333, 25.0, 25.0, 13.889]

    out["road_limits"] = ROAD_LIMITS

    out["plans"] = []
    for label, eta, stops, road in [
        ("free_flow", None, None, None),
        ("eta_slower", 400.0, None, None),
        ("eta_faster_than_physics", 20.0, None, None),
        ("with_waypoint_stop", 400.0, {3: 120.0}, None),
        ("road_limits_free_flow", None, None, ROAD_LIMITS),
        ("road_limits_optimistic_eta", 60.0, None, ROAD_LIMITS),
        # Clear road: the estimate is near free-flow, so the full speeding allowance applies.
        ("road_limits_light_traffic", 300.0, None, ROAD_LIMITS),
        # Queue: the estimate is far longer than free-flow, so nobody is over the limit.
        ("road_limits_heavy_traffic", 900.0, None, ROAD_LIMITS),
    ]:
        plan = build_plan(poly, expected_travel_time=eta, include_stops=False,
                          waypoint_stops=stops, road_limits=road)
        states = []
        for t in [0.0, 5.0, 30.0, 100.0, plan.total_time * 0.5, plan.total_time - 1.0,
                  plan.total_time, plan.total_time + 10.0]:
            pt, hdg, spd = plan.state_at(t)
            states.append({"t": R(t), "lat": R(pt.lat), "lon": R(pt.lon),
                           "heading": R(hdg), "speed": R(spd)})
        out["plans"].append({
            "label": label,
            "road_limits": road,
            "expected_travel_time": eta,
            "waypoint_stops": {str(k): v for k, v in (stops or {}).items()},
            "speeds": [R(v) for v in plan.speeds],
            "arrive": [R(v) for v in plan.arrive],
            "depart": [R(v) for v in plan.depart],
            "total_time": R(plan.total_time),
            "distance": R(plan.distance),
            "eta_achievable": plan.eta_achievable,
            "state_at": states,
        })

    return out


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(build(), indent=2) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
