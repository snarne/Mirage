import json
import os
import pathlib
import pytest
from datetime import datetime, timedelta, timezone

from mirage.consent import (
    AgeAttestation, ConsentError, ConsentStore, Eligibility, Grants, _managed_payloads,
    device_fingerprint,
)

ADULT = AgeAttestation(meets_threshold=True, lower_bound=18, declaration="confirmed",
                       source="DeclaredAgeRange")
FULL = Grants(allow_pin=True, allow_drive=True, max_session_minutes=30)
UDID = "test-device-a"


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setenv("MIRAGE_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def store(tmp_path):
    return ConsentStore(path=tmp_path / "consent.json")


# ---------------------------------------------------------------- age gating

def test_minor_cannot_grant_consent(store):
    minor = AgeAttestation(meets_threshold=False, lower_bound=13, upper_bound=17,
                           declaration="guardianDeclared", source="DeclaredAgeRange")
    with pytest.raises(ConsentError, match="not declared as 18"):
        store.grant(age=minor, grants=FULL, udid=UDID)
    assert store.load() is None


def test_active_parental_controls_block_even_if_over_18(store):
    """The parental-controls signal outranks the age range: an adult account under
    supervision is still supervised."""
    supervised_adult = AgeAttestation(
        meets_threshold=True, lower_bound=18, parental_controls_active=True,
        declaration="confirmed", source="DeclaredAgeRange")
    with pytest.raises(ConsentError, match="[Pp]arental controls"):
        store.grant(age=supervised_adult, grants=FULL, udid=UDID)


def test_adult_can_grant(store):
    record = store.grant(age=ADULT, grants=FULL, udid=UDID)
    assert not record.expired
    assert store.load() is not None


# ------------------------------------------------------------- enforcement

def test_no_consent_refuses_everything(store):
    with pytest.raises(ConsentError, match="No consent"):
        store.require("pin", UDID)


def test_ungranted_action_is_refused(store):
    store.grant(age=ADULT, grants=Grants(allow_pin=True, allow_drive=False), udid=UDID)
    store.require("pin", UDID)                      # allowed
    with pytest.raises(ConsentError, match="not allowed drive"):
        store.require("drive", UDID)


def test_expired_consent_is_refused(store):
    store.grant(age=ADULT, grants=FULL, udid=UDID, validity_days=0)
    record = store.load()
    record.expires_at = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    store.save(record)
    with pytest.raises(ConsentError, match="expired"):
        store.require("pin", UDID)


def test_consent_is_bound_to_one_device(store):
    """A grant made on an adult's own phone must not unlock a different one."""
    store.grant(age=ADULT, grants=FULL, udid=UDID)
    with pytest.raises(ConsentError, match="different iPhone"):
        store.require("pin", "test-device-b")


def test_revoke_clears_the_record(store):
    store.grant(age=ADULT, grants=FULL, udid=UDID)
    store.revoke()
    with pytest.raises(ConsentError):
        store.require("pin", UDID)


def test_corrupt_record_is_treated_as_absent(store):
    store.path.write_text("{ not json")
    assert store.load() is None


# ------------------------------------------------------------- fingerprint

def test_fingerprint_never_contains_the_raw_udid(store):
    fp = device_fingerprint(UDID)
    assert UDID not in fp
    assert len(fp) == 32

    store.grant(age=ADULT, grants=FULL, udid=UDID)
    written = store.path.read_text()
    assert UDID not in written, "raw UDID must never be written to disk"


def test_fingerprint_is_stable_and_distinct():
    assert device_fingerprint(UDID) == device_fingerprint(UDID)
    assert device_fingerprint(UDID) != device_fingerprint("test-device-b")


# ------------------------------------------------------------- eligibility

def test_supervised_device_is_ineligible():
    e = Eligibility(supervised=True, checked=True)
    assert not e.ok
    assert any("supervised" in r.lower() for r in e.blocking_reasons)


def test_dep_enrolled_device_is_ineligible():
    e = Eligibility(dep_enrolled=True, checked=True)
    assert not e.ok
    assert any("enrol" in r.lower() for r in e.blocking_reasons)


def test_restriction_profile_makes_device_ineligible():
    e = Eligibility(managed_profiles=["Screen Time Restrictions"], checked=True)
    assert not e.ok


def test_clean_device_is_eligible():
    assert Eligibility(checked=True).ok


def test_unchecked_device_is_not_treated_as_eligible():
    """Failing to check must never read as a pass."""
    assert not Eligibility(checked=False).ok


def test_managed_payload_detection():
    profiles = {
        "OrderedIdentifiers": ["com.apple.mdm.acme", "com.example.wifi"],
        "ProfileMetadata": {
            "com.apple.applicationaccess.restrictions": {"PayloadDisplayName": "Restrictions"},
            "com.example.vpn": {"PayloadDisplayName": "Work VPN"},
        },
    }
    found = _managed_payloads(profiles)
    assert "Restrictions" in found
    assert any("mdm" in f.lower() for f in found)
    assert "Work VPN" not in found


# ------------------------------------------- regression: personal device is eligible

@pytest.mark.asyncio
async def test_ordinary_personal_device_is_not_flagged_as_managed():
    """Every device returns a cloud-configuration dictionary, managed or not.

    Treating its mere presence as MDM enrolment blocked ordinary personal iPhones.
    These are the real values read from an unmanaged device.
    """
    from mirage.consent import check_eligibility

    class FakeRSD:
        async def get_value(self, key=None):
            raise RuntimeError("MissingValue")

    cloud = {
        "AllowPairing": True,
        "CloudConfigurationUIComplete": True,
        "ConfigurationSource": 0,
        "IsSupervised": False,
        "PostSetupProfileWasInstalled": True,
    }

    import mirage.consent as consent_mod

    class FakeService:
        def __init__(self, _p): pass
        async def get_cloud_configuration(self): return cloud
        async def get_profile_list(self): return {"OrderedIdentifiers": [], "ProfileMetadata": {}}

    import sys, types
    fake_mod = types.ModuleType("pymobiledevice3.services.mobile_config")
    fake_mod.MobileConfigService = FakeService
    saved = sys.modules.get("pymobiledevice3.services.mobile_config")
    sys.modules["pymobiledevice3.services.mobile_config"] = fake_mod
    try:
        result = await check_eligibility(FakeRSD())
    finally:
        if saved is not None:
            sys.modules["pymobiledevice3.services.mobile_config"] = saved
        else:
            del sys.modules["pymobiledevice3.services.mobile_config"]

    assert result.checked
    assert result.ok, f"unmanaged device wrongly blocked: {result.blocking_reasons}"
    assert not result.supervised
    assert not result.dep_enrolled


@pytest.mark.asyncio
async def test_supervised_flag_inside_cloud_config_is_honoured():
    from mirage.consent import check_eligibility
    import sys, types

    class FakeRSD:
        async def get_value(self, key=None):
            raise RuntimeError("MissingValue")

    class FakeService:
        def __init__(self, _p): pass
        async def get_cloud_configuration(self):
            return {"IsSupervised": True, "ConfigurationSource": 1}
        async def get_profile_list(self): return {}

    fake_mod = types.ModuleType("pymobiledevice3.services.mobile_config")
    fake_mod.MobileConfigService = FakeService
    saved = sys.modules.get("pymobiledevice3.services.mobile_config")
    sys.modules["pymobiledevice3.services.mobile_config"] = fake_mod
    try:
        result = await check_eligibility(FakeRSD())
    finally:
        if saved is not None:
            sys.modules["pymobiledevice3.services.mobile_config"] = saved
        else:
            del sys.modules["pymobiledevice3.services.mobile_config"]

    assert not result.ok
    assert result.supervised and result.dep_enrolled


# ------------------------------------------------- forward/backward compatibility

def test_record_written_by_an_older_version_still_loads(store):
    """A consent record outlives the code that wrote it. A field this version has since
    dropped must not invalidate someone's consent and force them back through setup."""
    import json
    store.path.write_text(json.dumps({
        "granted_at": "2026-01-01T00:00:00+00:00",
        "expires_at": "2099-01-01T00:00:00+00:00",
        "device_fingerprint": device_fingerprint(UDID),
        "age": {"meets_threshold": True, "threshold": 18, "source": "DeclaredAgeRange",
                "some_removed_field": "whatever"},
        "grants": {"allow_pin": True, "allow_drive": True, "max_session_minutes": 30,
                   "show_persistent_indicator": True},
    }))
    record = store.load()
    assert record is not None, "an unknown field must not discard the record"
    assert record.grants.allow_pin and record.grants.allow_drive
    store.require("pin", UDID)


def test_record_missing_newer_fields_uses_restrictive_defaults(store):
    import json
    store.path.write_text(json.dumps({
        "granted_at": "2026-01-01T00:00:00+00:00",
        "expires_at": "2099-01-01T00:00:00+00:00",
        "device_fingerprint": device_fingerprint(UDID),
        "age": {"meets_threshold": True},
        "grants": {"allow_pin": True},
    }))
    record = store.load()
    assert record.grants.allow_pin
    assert not record.grants.allow_drive, "absent permissions must default to denied"
