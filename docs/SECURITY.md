# Mirage — Threat Model

The user connects their iPhone — the device their Find My identity lives on — to this
software. That deserves an explicit account of what Mirage can reach, what it refuses to
touch, and what it cannot protect them from.

---

## 1. Mirage never handles Apple ID credentials

**There is no code path in this project that accepts an Apple ID, iCloud password, or
2FA code, and there must never be one.**

Mirage works at the device level over a USB pairing the user has already trusted. It has
no functional need for an iCloud login. Any tool in this category that asks for one is
either doing something it has not disclosed, or has built a phishing-shaped surface for
no benefit. The absence is a design guarantee, not an oversight — treat a future PR that
adds a credential field as a security regression.

## 2. The control channel

The engine's RPC can move the user's apparent position anywhere on earth. Anything that
can reach it can do that too, silently.

| Decision | Reason |
|---|---|
| **Unix domain socket, never TCP** | A `localhost` port is reachable by every process on the machine, and by web content via DNS rebinding. A socket file is not. |
| **`0700` parent directory, `0600` socket** | Kernel-enforced, not advisory. Created under a restrictive `umask` so there is no window between `bind()` and `chmod()`. |
| **`LOCAL_PEERCRED` uid check on every connection** | The kernel reports the connecting process's effective uid. Unlike anything the client could claim about itself, it cannot be forged. |
| **Fail closed** | Any error while verifying the peer is a refusal, not a warning. |
| **1 MiB line cap** | A route polyline is large; unbounded is a memory-exhaustion primitive. |

Implemented in `core/mirage/security.py`, tested in `core/tests/test_rpc.py`.

**Known gap — same-uid processes.** The uid check stops other users, not other programs
running as *this* user. Closing that would mean validating the client's code signature
against a designated requirement via its audit token. Until that exists, Mirage's control
channel is exactly as trustworthy as the rest of the user's login session.

This section is about the Mac app only. The iPhone app has no control channel: the engine
runs in-process, so there is nothing for another program to connect to.

## 3. No privileged helper — and that is a security win

Mirage ships no privileged helper. It opens Apple's native `remotepairingd` tunnel
in-process via `NativeRemotedTunnel`, which runs entirely unprivileged — verified on a
real device against pymobiledevice3 11.12.5.

The alternative transport, `pymobiledevice3`'s `tunneld` daemon, *does* require root. Mirage
will attach to one that is already running, but never starts one, and does not need one.

This is worth stating as a security property rather than a convenience: a root daemon with
an IPC interface is *the* classic macOS local-privilege-escalation hole. Not shipping one
removes that entire class of vulnerability from Mirage. **Mirage runs wholly as the
logged-in user and should stay that way.**

If a future need forces the classic tunnel (`--no-native`, or a Linux port), the helper
must derive client identity from the **audit token**, never the PID — PIDs are reused and
a process can be swapped between check and use — validate it against a designated
requirement via `SecCodeCheckValidityWithErrors`, and expose only tunnel up/down, never a
general device-command proxy.

## 4. What is exposed on the device

Enabling Developer Mode is a real, persistent expansion of the device's attack surface:
it permanently lowers the bar for anyone with **physical access plus a trusted computer**.
This is a genuine cost, not a formality, and Mirage should say so in its first-run flow
and offer a one-click path to turn it back off.

A pairing record is a long-lived credential granting full device access — filesystem,
installed apps, backups. Anything that exfiltrates one has effectively exfiltrated the
phone.

**The Mac app never copies, exports or stores pairing records.** It uses the system
`usbmuxd` store in place.

**The iPhone app cannot work that way, and this is the one place Mirage makes a real
trade.** An app on the phone has no access to the Mac's `usbmuxd` store, so
`scripts/prepare-phone.sh` mints a credential and you carry it across. Three things follow,
and they are worth stating rather than burying:

1. **It is a separate credential, not a copy of the Mac's.** `mirage-pair` runs its own
   RemotePairing pair-setup and gets a fresh Ed25519 keypair. Revoking it does not
   disturb the Mac's pairing, and it carries no RSA certificate material from it.
2. **It exists as a loose file for as long as it takes you to move it.** The script writes
   it to the Desktop at mode 0600, deliberately outside the repository so it cannot be
   committed by accident, and tells you to delete it once the phone has it. `.gitignore`
   covers the filenames as a second line of defence. Nothing stops you leaving it there.
3. **On the phone it is inside the app container**, excluded from iCloud backups —
   otherwise it would ride a backup onto Apple's servers and into any future restore —
   and protected at rest with `completeUntilFirstUserAuthentication`. Not `complete`,
   which sounds stronger and would be wrong: files under `complete` are unreadable while
   the phone is locked, which is precisely when a drive is running.

The honest summary: the iPhone app moves a device credential across an AirDrop and stores
it on the phone. That is strictly more exposure than the Mac app, it is the price of not
needing the Mac every time, and no amount of care at the destination changes the fact that
the file briefly exists in the open.

## 5. Logging and telemetry

Location history is among the most sensitive data a person has.

- **No analytics, no crash reporting, no network egress** from the engine other than to
  the device itself. Route planning talks to Apple because `MKDirections` is Apple's
  service; nothing else leaves the machine.
- UDIDs are **redacted** in logs to a prefix and suffix — a UDID is a stable unique
  device identifier and logs get pasted into bug reports.
- Coordinates are logged at **one decimal place (~11 km)** — enough to debug a routing
  problem, not enough to reconstruct where somebody was.
- Session state lives in the `0700` state directory, local only.
- **Saved trips are location data.** `trips.json` holds places the user cared about enough
  to save, which is exactly the kind of history worth protecting. It is written `0600` in
  the same owner-only directory, never leaves the machine, and is written atomically —
  temporary file, then replace — so an interrupted write cannot corrupt it. A file that
  fails to parse is discarded rather than throwing on every launch, and coordinates that
  are non-finite or out of range are dropped on load rather than reaching MapKit.

## 6. Persistence, and the obligation that comes with it

**A simulated location outlives Mirage.** The override lives in `locationd` on the phone.
Closing the app, unplugging the cable, the Mac sleeping, the engine crashing — none of
these cancel it. Nothing does until a stop is sent or the device reboots.

This is deliberate, and it is the behaviour users want: it is what lets someone set a
location and then walk away from the Mac. Mirage therefore **never clears the device on
its own**, not on startup and not on disconnect. Silently undoing a location someone
chose would be surprising in the one direction they cannot undo.

The obligation that comes with that is not "always clear" but **always tell, and always
be able to undo**:

- **The app says so on reopening.** If the previous run ended mid-session, the first
  thing shown is that the phone may still be simulating, with *Restore Real Location* and
  *Keep It* side by side. It offers; it does not decide.
- **Restore reconnects.** The usual reason a stop fails is that the channel died with the
  session. `restore()` rebuilds the tunnel and retries rather than failing on the corpse
  of the old one. This was a real defect: a tick loop killed by the phone disconnecting
  made `stop()` and `restore()` raise too, because awaiting the dead task re-raised its
  exception — so the one control that could recover the situation was the one guaranteed
  to fail.
- **Failure states the consequence.** When the phone genuinely cannot be reached, the
  error does not say "operation failed". It says the phone is still reporting a false
  location, and how to fix it: reconnect it, or reboot it.
- **Mirage remembers, durably.** The DVT channel is write-only — it sets a location and
  clears one, and nothing reads the current state back. Mirage can therefore never *ask*
  a phone whether it is simulating; it can only remember having made it so. That memory
  is the only thing between a user and a device stuck on a false location, so it lives in
  a marker file that is written the moment a fix is actually delivered, fsynced before
  rename, and cleared **only** when a stop is confirmed — never when a notice is
  dismissed, a window is closed, or a session object goes away. An unreadable marker is
  treated as *active*, because forgetting is the one failure with no recovery.
- **The notice is not dismissible.** An earlier version cleared its flag when the user
  dismissed it, so Mirage forgot the device was simulating and could never offer to undo
  it again. The banner now disappears only when a restore is confirmed.
- **A restore requested while offline is completed later.** If the phone is unreachable
  when someone asks to restore, the request is persisted and carried out as soon as the
  device reconnects. Finishing a request the user already made is not a silent change —
  it is the opposite of being stranded.
- **Restore is never gated.** Not on consent, not on eligibility, not on what state the
  engine believes it is in.
- **The session length holds rather than clears.** When the consented duration elapses,
  Mirage stops advancing the journey, keeps reporting the position it had reached, and
  raises a notice with *Restore* and *Keep Holding*. It is a reminder, not a kill switch:
  the user may not be at the Mac when it fires, and undoing a location they chose is
  theirs to decide.
- **A lost connection is not an error.** The trajectory is driven by the clock, not by
  what was delivered, so a journey continues through a disconnection and the first fix
  after reconnecting is wherever the driver would be by then. The tunnel is retried in
  the background so a slow reconnect never stalls the simulated clock.

The residual risk is honest and worth stating: **a user who sets a location, unplugs, and
forgets will stay at that location indefinitely.** Rebooting the iPhone clears it. Mirage
cannot reach a phone that is not connected, and pretending otherwise would be worse than
saying it plainly.

## 7. Eligibility and consent

Mirage will not start a session until two separate conditions hold. They are deliberately
not conflated.

**Eligibility — what the device says.** Before anything else, the engine asks the connected
iPhone whether it is supervised, enrolled in MDM, or carrying a restriction profile
(`com.apple.mdm`, `com.apple.applicationaccess`, content filters). Any of those means
someone other than the person at the keyboard sets policy on that phone — a school,
employer, or family organiser. Mirage refuses, and no consent on file overrides it.

This is the check with real teeth. Faking it means actually removing the management
profile, which on a supervised device requires the supervising party's credentials.

**Consent — what the owner says.** An age attestation plus explicit grants. On macOS 26+
the age check uses Apple's `DeclaredAgeRange`, which answers from the user's Apple Account
rather than a checkbox, and reports whether **parental controls are active on the account**.
That signal alone blocks the session, even for an account whose age range clears 18: an
adult account under supervision is still supervised. Mirage never sees a date of birth.

**The Apple path requires a Developer ID-signed build.** Apple does not serve account age
data to an ad-hoc signed binary with no Team Identifier — reasonably, since otherwise any
unsigned program could read a user's age bracket. A build from source therefore falls back
to a self-attested date of birth, recorded as `source: "self-attested"` so the consent
record never overstates how the age was established, and labelled as unverified in the UI.

This is a real limitation and worth being blunt about: **in an unsigned build, the age gate
is self-attestation and the parental-controls signal is unavailable.** The device
eligibility check above is unaffected, and it remains the control that actually resists
bypass — a phone managed by a parent is refused regardless of what anyone types into a
date field.

The grants are per-capability (hold a location / simulate a drive), carry a maximum session
duration the engine enforces, expire after 30 days, and are bound to a salted hash of the
device's UDID — so a grant made on one phone cannot unlock another. The raw UDID is never
written to disk.

Enforcement lives in the **engine**, not the UI. A gate in the UI is bypassed by opening
the control socket directly.

### How strong is this, honestly

The eligibility check genuinely resists bypass. The consent record does not: it is a local
JSON file, and an adult with a text editor can forge one. It is not DRM and is not sold as
such. Its purpose is to make misuse a deliberate act rather than an accident, to refuse the
specific case of a managed device outright, and to make what the owner agreed to explicit,
time-limited, and revocable.

What it is designed to stop: a minor using this to defeat parental controls or Family
Sharing location, on a device a parent manages. What it cannot stop: a determined adult.
That is the correct place to draw the line for a tool like this.

## 8. What Mirage does not protect against

Stated plainly, because the gap between what users assume and what is true is where
people get hurt:

- **The offline Find My network.** Spoofing covers only the device's self-reported
  location. If the phone goes offline or is powered off, nearby strangers' Apple devices
  report its **real** position over BLE. This bypasses `locationd` entirely.
- **Apple's server-side view.** Apple sees the connecting IP address. Find My does not
  surface it to sharing contacts, but it is an inconsistency if Apple is in the threat
  model.
- **Anyone holding the phone.** The override is device-wide: Weather, Maps, Siri
  suggestions and photo EXIF all relocate. Significant Locations logs the fake positions.
  These are visible to anyone who picks up the device.
- **Forensic examination.** Developer Mode, the DDI mount, and Significant Locations all
  leave traces.

---

## Reporting a vulnerability

Open a [security advisory](../../security/advisories/new) rather than a public issue, and
please include what an attacker would gain — the classes of problem that matter most here
are:

- anything that lets another process on the machine drive the control socket;
- anything that leaves a device simulating a location without the user being told, or with
  no way to undo it;
- anything that writes a raw device identifier, an Apple Account detail, or a precise
  coordinate to disk or a log.

There is no bounty. This is a small project; expect a reply in days rather than hours.

## Scope

Mirage runs entirely on one machine as one user, with no server, no account, and no network
egress beyond Apple's own routing and device services. There is no remote attack surface to
report against — the trust boundaries that exist are the control socket, the device pairing,
and the files in the state directory.
