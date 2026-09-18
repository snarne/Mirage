"""Eligibility checks and the owner's consent record.

Two separate ideas, deliberately not conflated:

**Eligibility** is what the *device* tells us. A supervised iPhone, one enrolled in MDM,
or one carrying a parental-restriction profile is a managed device — very often a
child's, a school's, or an employer's. Mirage refuses to operate on those. This check is
the one with real teeth: faking it means actually removing the management profile, which
on a supervised device needs the supervising party's credentials.

**Consent** is what the *owner* tells us: an age attestation and a set of explicit
grants. This is recorded, bound to the device it was granted for, and expires.

An honest word on strength. Consent is a local record, and a determined adult with a
text editor can forge one. It is not DRM and is not sold as such. Its job is to make
misuse a deliberate act rather than an accident, to stop the specific case of a managed
device being spoofed, and to make what the owner agreed to explicit and revocable. The
eligibility check is the part that genuinely resists bypass.

Enforcement lives in the engine rather than the UI, because a gate in the UI is bypassed
by opening the control socket directly.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
from dataclasses import asdict, dataclass, field, fields
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .security import device_fingerprint, state_dir

log = logging.getLogger(__name__)

CONSENT_FILE = "consent.json"
DEFAULT_VALIDITY_DAYS = 30

# Configuration-profile payload types that mark a device as managed. Presence of any of
# these means someone other than the person at the keyboard sets policy on this phone.
MANAGED_PAYLOAD_TYPES = {
    "com.apple.mdm",
    "com.apple.applicationaccess",          # Restrictions (Screen Time / parental)
    "com.apple.applicationaccess.new",
    "com.apple.familycontrols.contentfilter",
    "com.apple.webcontent-filter",
}


class ConsentError(Exception):
    """Raised when an operation is attempted without valid consent."""

    def __init__(self, message: str, remedy: str = "") -> None:
        super().__init__(message)
        self.remedy = remedy or "Complete the setup flow in Mirage to grant consent."


# --------------------------------------------------------------------------- age

@dataclass(frozen=True)
class AgeAttestation:
    """Result of the platform age check, recorded verbatim.

    On macOS 26+ this comes from Apple's `DeclaredAgeRange` framework, so the age range
    and whether parental controls are active are attested by the user's Apple Account
    rather than self-reported in a checkbox.
    """

    meets_threshold: bool
    threshold: int = 18
    lower_bound: int | None = None
    upper_bound: int | None = None
    declaration: str = "unknown"            # selfDeclared | guardianDeclared | confirmed
    parental_controls_active: bool = False
    source: str = "unknown"                 # "DeclaredAgeRange" | "unavailable"

    @property
    def blocking_reason(self) -> str | None:
        if self.parental_controls_active:
            return (
                "Parental controls are active on this Apple Account. Mirage will not run "
                "on an account under parental supervision."
            )
        if not self.meets_threshold:
            return f"This Apple Account is not declared as {self.threshold} or older."
        return None


# -------------------------------------------------------------------- eligibility

@dataclass
class Eligibility:
    """What the connected device says about who controls it."""

    supervised: bool = False
    dep_enrolled: bool = False
    managed_profiles: list[str] = field(default_factory=list)
    checked: bool = False
    check_error: str | None = None

    @property
    def blocking_reasons(self) -> list[str]:
        out = []
        if self.supervised:
            out.append(
                "This iPhone is supervised. Supervised devices are managed by a school, "
                "employer, or family organiser."
            )
        if self.dep_enrolled:
            out.append(
                "This iPhone is enrolled in automated device enrolment (Apple Business "
                "or School Manager)."
            )
        if self.managed_profiles:
            out.append(
                "This iPhone has restriction profiles installed: "
                + ", ".join(sorted(set(self.managed_profiles)))
            )
        return out

    @property
    def ok(self) -> bool:
        return self.checked and not self.blocking_reasons

    def to_json(self) -> dict[str, Any]:
        d = asdict(self)
        d["ok"] = self.ok
        d["blocking_reasons"] = self.blocking_reasons
        return d


async def check_eligibility(service_provider) -> Eligibility:
    """Interrogate the device for signs it is managed by someone else.

    Failures are recorded rather than raised: an older iOS version that does not answer
    one of these queries should not be treated as proof of innocence *or* guilt, so the
    caller sees `checked` and decides.
    """
    result = Eligibility()
    try:
        from pymobiledevice3.services.mobile_config import MobileConfigService

        try:
            # Not present on every iOS version; absence is not evidence either way, so
            # the cloud-configuration value below is consulted regardless.
            result.supervised = bool(await service_provider.get_value(key="IsSupervised"))
        except Exception as exc:  # noqa: BLE001
            log.debug("IsSupervised lockdown value unavailable: %s", exc)

        service = MobileConfigService(service_provider)
        try:
            # Every device returns a cloud-configuration dictionary, including a
            # completely unmanaged personal one — its *presence* means nothing. The
            # signals are the values inside it: IsSupervised, and a non-zero
            # ConfigurationSource, which indicates enrolment via Apple Business or
            # School Manager rather than manual setup.
            cloud = await service.get_cloud_configuration() or {}
            if not result.supervised:
                result.supervised = bool(cloud.get("IsSupervised", False))
            result.dep_enrolled = int(cloud.get("ConfigurationSource", 0) or 0) != 0
            if cloud.get("IsMDMUnremovable") or cloud.get("IsMandatory"):
                result.dep_enrolled = True
        except Exception as exc:  # noqa: BLE001
            log.debug("cloud configuration unavailable: %s", exc)

        try:
            profiles = await service.get_profile_list()
            result.managed_profiles = _managed_payloads(profiles)
        except Exception as exc:  # noqa: BLE001
            log.debug("profile list unavailable: %s", exc)

        result.checked = True
    except Exception as exc:  # noqa: BLE001
        result.check_error = str(exc)
        log.warning("eligibility check failed: %s", exc)
    return result


def _managed_payloads(profile_list: dict[str, Any]) -> list[str]:
    """Pull the human-readable names of any management/restriction profiles."""
    found: list[str] = []
    metadata = (profile_list or {}).get("ProfileMetadata") or {}
    for identifier, meta in metadata.items():
        name = (meta or {}).get("PayloadDisplayName") or identifier
        if any(t in str(identifier).lower() for t in ("mdm", "restrict", "familycontrol")):
            found.append(str(name))
    for profile in (profile_list or {}).get("OrderedIdentifiers", []) or []:
        if any(t in str(profile).lower() for t in ("mdm", "restrict", "familycontrol")):
            found.append(str(profile))
    return found


# ------------------------------------------------------------------------ grants

@dataclass
class Grants:
    """What the owner has explicitly allowed. Defaults are the restrictive ones."""

    allow_pin: bool = False
    allow_drive: bool = False
    max_session_minutes: int = 60

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ConsentRecord:
    granted_at: str
    expires_at: str
    device_fingerprint: str
    age: AgeAttestation
    grants: Grants

    def to_json(self) -> dict[str, Any]:
        return {
            "granted_at": self.granted_at,
            "expires_at": self.expires_at,
            "device_fingerprint": self.device_fingerprint,
            "age": asdict(self.age),
            "grants": self.grants.to_json(),
        }

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "ConsentRecord":
        return cls(
            granted_at=d["granted_at"],
            expires_at=d["expires_at"],
            device_fingerprint=d["device_fingerprint"],
            age=_build(AgeAttestation, d.get("age")),
            grants=_build(Grants, d.get("grants")),
        )

    @property
    def expired(self) -> bool:
        try:
            return datetime.now(timezone.utc) >= datetime.fromisoformat(self.expires_at)
        except ValueError:
            return True


def _build(cls, payload: dict[str, Any] | None):
    """Construct from stored JSON, ignoring fields this version no longer knows about.

    A consent record outlives the code that wrote it. Passing unknown keys straight into
    the constructor meant that removing a field made every existing record undecodable —
    so an upgrade silently threw away the user's consent and sent them back through
    setup. Unknown keys are dropped; missing ones fall back to the dataclass defaults,
    which are the restrictive ones.
    """
    known = {f.name for f in fields(cls)}
    return cls(**{k: v for k, v in (payload or {}).items() if k in known})


class ConsentStore:
    """Persists the consent record in the owner-only state directory."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (state_dir() / CONSENT_FILE)

    def load(self) -> ConsentRecord | None:
        if not self.path.exists():
            return None
        try:
            return ConsentRecord.from_json(json.loads(self.path.read_text()))
        except Exception as exc:  # noqa: BLE001
            log.warning("consent record unreadable, treating as absent: %s", exc)
            return None

    def save(self, record: ConsentRecord) -> None:
        self.path.write_text(json.dumps(record.to_json(), indent=2))
        os.chmod(self.path, 0o600)
        log.info("consent recorded, expires %s", record.expires_at)

    def revoke(self) -> None:
        if self.path.exists():
            self.path.unlink()
        log.info("consent revoked")

    def grant(
        self,
        *,
        age: AgeAttestation,
        grants: Grants,
        udid: str | None,
        validity_days: int = DEFAULT_VALIDITY_DAYS,
    ) -> ConsentRecord:
        reason = age.blocking_reason
        if reason:
            raise ConsentError(reason, remedy="Mirage cannot be used on this account.")
        now = datetime.now(timezone.utc)
        record = ConsentRecord(
            granted_at=now.isoformat(),
            expires_at=(now + timedelta(days=validity_days)).isoformat(),
            device_fingerprint=device_fingerprint(udid),
            age=age,
            grants=grants,
        )
        self.save(record)
        return record

    # -- enforcement ----------------------------------------------------

    def require(self, action: str, udid: str | None) -> ConsentRecord:
        """Raise unless a valid, unexpired grant covers `action` for this device."""
        record = self.load()
        if record is None:
            raise ConsentError("No consent has been granted on this Mac.")
        if record.expired:
            raise ConsentError(
                "Consent has expired.", remedy="Re-confirm consent in Mirage to continue."
            )
        expected = device_fingerprint(udid)
        if record.device_fingerprint not in ("unknown", expected):
            raise ConsentError(
                "Consent was granted for a different iPhone.",
                remedy="Grant consent again for the device now connected.",
            )
        allowed = {"pin": record.grants.allow_pin, "drive": record.grants.allow_drive}
        if not allowed.get(action, False):
            raise ConsentError(
                f"The owner of this Mac has not allowed {action}.",
                remedy="Change what is allowed in Mirage's setup.",
            )
        return record
