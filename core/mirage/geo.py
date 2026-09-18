"""Spherical geometry and arc-length indexed polylines.

All distances are metres, all bearings degrees clockwise from true north.
"""
from __future__ import annotations

import bisect
import math
from dataclasses import dataclass

R_EARTH = 6371008.8  # IUGG mean radius


@dataclass(frozen=True, slots=True)
class LatLon:
    lat: float
    lon: float


def haversine(a: LatLon, b: LatLon) -> float:
    """Great-circle distance in metres."""
    p1, p2 = math.radians(a.lat), math.radians(b.lat)
    dp = p2 - p1
    dl = math.radians(b.lon - a.lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R_EARTH * math.asin(min(1.0, math.sqrt(h)))


def bearing(a: LatLon, b: LatLon) -> float:
    """Initial bearing from a to b, in [0, 360)."""
    p1, p2 = math.radians(a.lat), math.radians(b.lat)
    dl = math.radians(b.lon - a.lon)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return math.degrees(math.atan2(y, x)) % 360.0


def destination(origin: LatLon, bearing_deg: float, distance_m: float) -> LatLon:
    """Point reached travelling `distance_m` from `origin` on `bearing_deg`."""
    d = distance_m / R_EARTH
    br = math.radians(bearing_deg)
    p1, l1 = math.radians(origin.lat), math.radians(origin.lon)
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(br))
    l2 = l1 + math.atan2(
        math.sin(br) * math.sin(d) * math.cos(p1),
        math.cos(d) - math.sin(p1) * math.sin(p2),
    )
    return LatLon(math.degrees(p2), (math.degrees(l2) + 540) % 360 - 180)


def circumradius(p0: LatLon, p1: LatLon, p2: LatLon) -> float:
    """Radius of the circle through three points — the local turn radius at p1.

    Returns ``inf`` for collinear points. Uses Kahan's numerically stable
    triangle-area formula; naive Heron loses all precision on the sliver
    triangles that dense road polylines are made of.
    """
    a, b, c = haversine(p1, p2), haversine(p0, p2), haversine(p0, p1)
    x, y, z = sorted((a, b, c), reverse=True)  # x >= y >= z
    t = (x + (y + z)) * (z - (x - y)) * (z + (x - y)) * (x + (y - z))
    if t <= 0:
        return math.inf
    area = 0.25 * math.sqrt(t)
    if area < 1e-9:
        return math.inf
    return (a * b * c) / (4.0 * area)


def turn_angle(p0: LatLon, p1: LatLon, p2: LatLon) -> float:
    """Absolute heading change at p1, in degrees [0, 180]."""
    delta = (bearing(p1, p2) - bearing(p0, p1) + 180.0) % 360.0 - 180.0
    return abs(delta)


class Polyline:
    """A path with cumulative arc-length indexing, so any distance along it
    maps to a coordinate in O(log n)."""

    __slots__ = ("points", "cumulative")

    def __init__(self, points: list[LatLon]) -> None:
        if len(points) < 2:
            raise ValueError("a polyline needs at least two points")
        # Drop consecutive duplicates; zero-length segments break the speed solver.
        cleaned = [points[0]]
        for p in points[1:]:
            if haversine(cleaned[-1], p) > 1e-3:
                cleaned.append(p)
        if len(cleaned) < 2:
            raise ValueError("polyline collapsed to a single point")
        self.points = cleaned
        self.cumulative = [0.0]
        for a, b in zip(cleaned, cleaned[1:]):
            self.cumulative.append(self.cumulative[-1] + haversine(a, b))

    def __len__(self) -> int:
        return len(self.points)

    @property
    def length(self) -> float:
        return self.cumulative[-1]

    def segment_lengths(self) -> list[float]:
        return [b - a for a, b in zip(self.cumulative, self.cumulative[1:])]

    def point_at(self, s: float) -> tuple[LatLon, float]:
        """Coordinate and heading at arc length `s` metres from the start."""
        s = max(0.0, min(s, self.length))
        i = max(0, min(bisect.bisect_right(self.cumulative, s) - 1, len(self.points) - 2))
        seg_len = self.cumulative[i + 1] - self.cumulative[i]
        a, b = self.points[i], self.points[i + 1]
        hdg = bearing(a, b)
        if seg_len <= 0:
            return a, hdg
        return destination(a, hdg, s - self.cumulative[i]), hdg

    def curvature_radii(self) -> list[float]:
        """Turn radius at each vertex; endpoints are unconstrained."""
        n = len(self.points)
        radii = [math.inf] * n
        for i in range(1, n - 1):
            radii[i] = circumradius(self.points[i - 1], self.points[i], self.points[i + 1])
        return radii
