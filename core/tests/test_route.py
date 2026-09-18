import pytest
from mirage.geo import LatLon, Polyline, destination, haversine
from mirage.route import VehicleLimits, build_plan


def straight(n=40, spacing=50.0):
    pts = [LatLon(37.7749, -122.4194)]
    for _ in range(n):
        pts.append(destination(pts[-1], 90.0, spacing))
    return Polyline(pts)


def with_corner():
    pts = [LatLon(37.7749, -122.4194)]
    for _ in range(20):
        pts.append(destination(pts[-1], 0.0, 50.0))     # 1 km north
    for _ in range(20):
        pts.append(destination(pts[-1], 90.0, 50.0))    # then 1 km east
    return Polyline(pts)


def test_plan_starts_and_ends_stationary():
    plan = build_plan(straight(), include_stops=False)
    assert plan.speeds[0] == 0.0
    assert plan.speeds[-1] == 0.0
    assert plan.state_at(0)[2] == 0.0
    assert plan.state_at(plan.total_time + 10)[2] == 0.0


def test_plan_honours_expected_travel_time():
    poly = straight()
    eta = 400.0
    plan = build_plan(poly, expected_travel_time=eta)
    assert plan.total_time == pytest.approx(eta, rel=0.02)


def test_traffic_makes_it_slower_not_shorter():
    """Doubling the ETA must halve the speeds, never change the path."""
    poly = straight()
    fast = build_plan(poly, expected_travel_time=200.0, seed=1)
    slow = build_plan(poly, expected_travel_time=400.0, seed=1)
    assert slow.total_time == pytest.approx(2 * fast.total_time, rel=0.05)
    assert slow.distance == pytest.approx(fast.distance)
    assert max(slow.speeds) < max(fast.speeds)


def test_slows_for_corners():
    plan = build_plan(with_corner(), include_stops=False)
    corner = 20
    assert plan.speeds[corner] < max(plan.speeds) * 0.6


def test_respects_acceleration_limits():
    limits = VehicleLimits()
    plan = build_plan(straight(n=60), include_stops=False)
    for i in range(len(plan.speeds) - 1):
        dt = plan.arrive[i + 1] - plan.depart[i]
        if dt <= 0:
            continue
        a = abs(plan.speeds[i + 1] - plan.speeds[i]) / dt
        assert a <= max(limits.a_accel, limits.a_brake) * 1.05


def test_never_exceeds_v_max():
    plan = build_plan(straight(n=200), include_stops=False)
    assert max(plan.speeds) <= VehicleLimits().v_max * 1.001


def test_position_is_monotonic_along_route():
    plan = build_plan(with_corner(), expected_travel_time=300.0, seed=7)
    start = plan.polyline.points[0]
    last = -1.0
    for i in range(0, int(plan.total_time)):
        p, _, speed = plan.state_at(float(i))
        d = haversine(start, p)
        assert speed >= -1e-6
        assert d >= last - 1.0  # tolerate corner geometry, never real backtracking
        last = d


def test_no_teleports_between_ticks():
    """Consecutive 1 Hz fixes must be a plausible distance apart."""
    plan = build_plan(with_corner(), expected_travel_time=300.0, seed=3)
    prev, _, _ = plan.state_at(0.0)
    for i in range(1, int(plan.total_time)):
        cur, _, _ = plan.state_at(float(i))
        assert haversine(prev, cur) <= VehicleLimits().v_max * 1.2
        prev = cur


def test_stops_are_deterministic_per_seed():
    poly = with_corner()
    a = build_plan(poly, seed=42).total_time
    b = build_plan(poly, seed=42).total_time
    assert a == b


def test_stops_add_time():
    poly = with_corner()
    without = build_plan(poly, include_stops=False, seed=5).total_time
    with_ = build_plan(poly, include_stops=True, seed=5).total_time
    assert with_ >= without


def test_impossible_eta_clamps_to_physics_and_reports_it():
    """An ETA faster than the route can be driven must not produce 1200 km/h."""
    poly = straight(n=40, spacing=50.0)  # 2 km
    plan = build_plan(poly, expected_travel_time=8.0, include_stops=False)
    assert max(plan.speeds) <= VehicleLimits().v_max * 1.001
    assert plan.eta_achievable is False
    assert plan.total_time > 8.0
    assert plan.requested_eta == 8.0


def test_achievable_eta_is_flagged_achievable():
    plan = build_plan(straight(), expected_travel_time=400.0)
    assert plan.eta_achievable is True
    assert plan.total_time == pytest.approx(400.0, rel=0.02)


def test_clamped_plan_still_respects_accel_limits():
    plan = build_plan(straight(n=40), expected_travel_time=8.0, include_stops=False)
    lim = VehicleLimits()
    for i in range(len(plan.speeds) - 1):
        dt = plan.arrive[i + 1] - plan.depart[i]
        if dt > 0:
            assert abs(plan.speeds[i + 1] - plan.speeds[i]) / dt <= max(lim.a_accel, lim.a_brake) * 1.05


# ------------------------------------------------------------ multi-stop trips

def test_waypoint_stop_adds_its_full_duration():
    """A stop the user asked for is added to the estimate, never scaled into it."""
    poly = straight(n=40)
    without = build_plan(poly, expected_travel_time=300.0, include_stops=False, seed=1)
    with_stop = build_plan(poly, expected_travel_time=300.0, include_stops=False, seed=1,
                           waypoint_stops={20: 120.0})
    assert with_stop.total_time == pytest.approx(without.total_time + 120.0, rel=0.05)


def test_vehicle_is_stationary_during_a_waypoint_stop():
    poly = straight(n=40)
    plan = build_plan(poly, expected_travel_time=200.0, include_stops=False,
                      waypoint_stops={20: 60.0})
    stop_start = plan.arrive[20]
    _, _, speed = plan.state_at(stop_start + 30.0)
    assert speed == pytest.approx(0.0, abs=1e-6)


def test_position_does_not_move_during_a_stop():
    poly = straight(n=40)
    plan = build_plan(poly, expected_travel_time=200.0, include_stops=False,
                      waypoint_stops={20: 60.0})
    a, _, _ = plan.state_at(plan.arrive[20] + 5.0)
    b, _, _ = plan.state_at(plan.arrive[20] + 50.0)
    assert haversine(a, b) == pytest.approx(0.0, abs=0.5)


def test_multiple_stops_all_honoured():
    poly = straight(n=60)
    base = build_plan(poly, expected_travel_time=400.0, include_stops=False, seed=3)
    multi = build_plan(poly, expected_travel_time=400.0, include_stops=False, seed=3,
                       waypoint_stops={15: 60.0, 30: 90.0, 45: 30.0})
    assert multi.total_time == pytest.approx(base.total_time + 180.0, rel=0.05)


def test_driving_time_still_matches_the_estimate_with_stops():
    poly = straight(n=40)
    plan = build_plan(poly, expected_travel_time=300.0, include_stops=False,
                      waypoint_stops={20: 600.0})
    assert plan.total_time - 600.0 == pytest.approx(300.0, rel=0.05)
    assert plan.eta_achievable


def test_out_of_range_stop_indices_are_ignored():
    poly = straight(n=20)
    plan = build_plan(poly, expected_travel_time=100.0, include_stops=False,
                      waypoint_stops={-5: 60.0, 9999: 60.0})
    assert plan.total_time == pytest.approx(100.0, rel=0.05)


def test_no_teleports_across_a_stop():
    poly = with_corner()
    plan = build_plan(poly, expected_travel_time=200.0, seed=2, waypoint_stops={20: 45.0})
    prev, _, _ = plan.state_at(0.0)
    for i in range(1, int(plan.total_time)):
        cur, _, _ = plan.state_at(float(i))
        assert haversine(prev, cur) <= VehicleLimits().v_max * 1.2
        prev = cur


# ── Posted speed limits ───────────────────────────────────────────────────────
#
# The Swift port has the same assertions in GoldenTests.swift. The golden values pin the
# arithmetic; these pin the behaviour, which is the part a reader needs to be able to
# check without running anything.


def test_an_unknown_limit_falls_back_to_the_vehicle_ceiling():
    # OSM leaves maxspeed off most ways, so this is the common case rather than an edge.
    poly = with_corner()
    plain = build_plan(poly, include_stops=False)
    zeros = build_plan(poly, include_stops=False, road_limits=[0.0] * len(poly.points))
    assert plain.speeds == pytest.approx(zeros.speeds)


def test_a_posted_limit_caps_however_optimistic_the_estimate():
    poly = with_corner()
    thirty = [30.0 / 3.6] * len(poly.points)

    unlimited = build_plan(poly, expected_travel_time=60.0, include_stops=False)
    limited = build_plan(poly, expected_travel_time=60.0, include_stops=False,
                         road_limits=thirty)

    # The ceiling is the sign plus the margin a real driver takes, never more. An estimate
    # demanding 120 km/h down a 30 km/h street cannot buy its way past it.
    ceiling = 30.0 / 3.6 + VehicleLimits().speeding_allowance
    assert max(limited.speeds) <= ceiling + 1e-9
    assert limited.total_time > unlimited.total_time
    assert not limited.eta_achievable


def test_drivers_sit_a_little_over_the_limit_on_a_clear_road():
    poly = straight(n=40)
    fifty = [50.0 / 3.6] * len(poly.points)
    # No estimate at all means no traffic signal, so the full allowance applies.
    plan = build_plan(poly, include_stops=False, road_limits=fifty)
    assert max(plan.speeds) > 50.0 / 3.6
    assert max(plan.speeds) <= 50.0 / 3.6 + VehicleLimits().speeding_allowance + 1e-9


def test_nobody_speeds_in_a_queue():
    poly = straight(n=40)
    fifty = [50.0 / 3.6] * len(poly.points)
    free = build_plan(poly, include_stops=False, road_limits=fifty)
    free_flow = free.total_time

    # An estimate twice the free-flow time is a jam. The allowance goes to zero there:
    # the one traffic signal Apple gives is route-wide, so this is a route-wide judgement.
    crawling = build_plan(poly, expected_travel_time=free_flow * 2.5, include_stops=False,
                          road_limits=fifty)
    assert max(crawling.speeds) <= 50.0 / 3.6 + 1e-9
