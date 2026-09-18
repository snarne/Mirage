import json
import pathlib
import pytest

from mirage.marker import SimulationMarker


@pytest.fixture
def marker(tmp_path):
    return SimulationMarker(tmp_path / "simulation.json")


def test_starts_clean(marker):
    assert not marker.active
    assert not marker.restore_pending


def test_marking_active_survives_a_restart(marker, tmp_path):
    marker.mark_active(37.7749, -122.4194, "UDID")
    # A new instance is what the next engine process sees.
    assert SimulationMarker(tmp_path / "simulation.json").active


def test_only_a_confirmed_stop_clears_it(marker, tmp_path):
    """The regression this exists for: the old flag was cleared when the user dismissed
    a notice, so Mirage forgot the device was simulating and could never offer to undo
    it again."""
    marker.mark_active(1.0, 2.0, "UDID")
    reopened = SimulationMarker(tmp_path / "simulation.json")
    assert reopened.active, "dismissing a notice must not clear the marker"

    reopened.mark_restored()
    assert not SimulationMarker(tmp_path / "simulation.json").active


def test_unreadable_marker_is_treated_as_active(tmp_path):
    """Forgetting is the one failure with no recovery, so a corrupt file errs toward
    telling the user rather than staying quiet."""
    path = tmp_path / "simulation.json"
    path.write_text("}{ not json")
    assert SimulationMarker(path).active


def test_pending_restore_persists(marker, tmp_path):
    marker.mark_active(1.0, 2.0, "UDID")
    marker.request_restore()
    reopened = SimulationMarker(tmp_path / "simulation.json")
    assert reopened.restore_pending
    assert reopened.active


def test_restoring_clears_both_flags(marker, tmp_path):
    marker.mark_active(1.0, 2.0, "UDID")
    marker.request_restore()
    marker.mark_restored()
    reopened = SimulationMarker(tmp_path / "simulation.json")
    assert not reopened.active
    assert not reopened.restore_pending


def test_marker_file_is_owner_only(marker):
    marker.mark_active(1.0, 2.0, "UDID")
    assert oct(marker.path.stat().st_mode)[-3:] == "600"


def test_no_temp_file_left_behind(marker):
    marker.mark_active(1.0, 2.0, "UDID")
    siblings = [p.name for p in marker.path.parent.iterdir()]
    assert not any(n.endswith(".tmp") for n in siblings)


def test_repeated_identical_fixes_do_not_rewrite(marker):
    marker.mark_active(1.0, 2.0, "UDID")
    first = marker.path.stat().st_mtime_ns
    for _ in range(5):
        marker.mark_active(1.0, 2.0, "UDID")
    assert marker.path.stat().st_mtime_ns == first, "must not write on every tick"


def test_describe_does_not_leak_precise_location(marker):
    marker.mark_active(37.774929, -122.419418, "test-device-primary")
    text = marker.describe()
    assert "37.774929" not in text, "log lines must not carry full precision"
    assert "device-primary" not in text, "log lines must not carry a full identifier"


def test_raw_device_identifier_never_reaches_disk(marker):
    """A UDID is a permanent, unique identifier for a physical device. Nothing reads it
    back, so keeping the real one would be liability with no function."""
    identifier = "SAMPLE-DEVICE-IDENTIFIER"
    marker.mark_active(1.0, 2.0, identifier)

    on_disk = marker.path.read_text()
    assert identifier not in on_disk, "the raw identifier must never be persisted"
    assert identifier not in marker.describe(), "nor reproduced in a log line"

    stored = json.loads(on_disk)
    assert stored["device"], "a salted fingerprint is still recorded"
    assert stored["device"] != identifier


def test_fingerprints_distinguish_devices():
    """Distinct devices must stay distinguishable, or the fingerprint is useless."""
    from mirage.security import device_fingerprint

    assert device_fingerprint("device-a") != device_fingerprint("device-b")
    assert device_fingerprint("device-a") == device_fingerprint("device-a")
