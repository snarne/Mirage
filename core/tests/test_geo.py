import math
import pytest
from mirage.geo import LatLon, Polyline, bearing, circumradius, destination, haversine, turn_angle

SF = LatLon(37.7749, -122.4194)
LA = LatLon(34.0522, -118.2437)


def test_haversine_known_distance():
    # SF -> LA is ~559 km great-circle
    assert haversine(SF, LA) == pytest.approx(559_000, rel=0.01)


def test_haversine_zero():
    assert haversine(SF, SF) == pytest.approx(0.0, abs=1e-6)


def test_bearing_cardinals():
    assert bearing(LatLon(0, 0), LatLon(1, 0)) == pytest.approx(0.0, abs=1e-6)     # north
    assert bearing(LatLon(0, 0), LatLon(0, 1)) == pytest.approx(90.0, abs=1e-6)    # east
    assert bearing(LatLon(0, 0), LatLon(-1, 0)) == pytest.approx(180.0, abs=1e-6)  # south


def test_destination_roundtrip():
    p = destination(SF, 45.0, 1000.0)
    assert haversine(SF, p) == pytest.approx(1000.0, rel=1e-6)
    assert bearing(SF, p) == pytest.approx(45.0, abs=1e-4)


def test_circumradius_straight_is_infinite():
    a, b, c = LatLon(0, 0), LatLon(0.001, 0), LatLon(0.002, 0)
    assert math.isinf(circumradius(a, b, c))


def test_circumradius_right_angle():
    # 100m north then 100m east -> circumradius of an isoceles right triangle
    # with legs 100m is hypotenuse/2 * sqrt(2) = 70.7m
    a = LatLon(0, 0)
    b = destination(a, 0, 100)
    c = destination(b, 90, 100)
    assert circumradius(a, b, c) == pytest.approx(70.71, rel=0.02)


def test_turn_angle():
    a = LatLon(0, 0)
    b = destination(a, 0, 100)
    c = destination(b, 90, 100)
    assert turn_angle(a, b, c) == pytest.approx(90.0, abs=0.5)


def test_polyline_arclength_and_lookup():
    pts = [LatLon(0, 0)]
    for _ in range(4):
        pts.append(destination(pts[-1], 90, 250))
    poly = Polyline(pts)
    assert poly.length == pytest.approx(1000.0, rel=1e-6)

    mid, hdg = poly.point_at(500.0)
    assert haversine(pts[0], mid) == pytest.approx(500.0, rel=1e-4)
    assert hdg == pytest.approx(90.0, abs=0.5)


def test_polyline_clamps_out_of_range():
    poly = Polyline([LatLon(0, 0), LatLon(0, 0.01)])
    assert poly.point_at(-50)[0].lon == pytest.approx(0.0)
    assert poly.point_at(1e9)[0].lon == pytest.approx(0.01)


def test_polyline_drops_duplicates():
    poly = Polyline([LatLon(0, 0), LatLon(0, 0), LatLon(0, 0.01)])
    assert len(poly) == 2


def test_polyline_rejects_degenerate():
    with pytest.raises(ValueError):
        Polyline([LatLon(0, 0), LatLon(0, 0)])
