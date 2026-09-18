# Architecture

## Why a host has to be involved at all

Find My reports a device's position through two independent channels:

| Channel | Producer | Used when |
|---|---|---|
| Self-reported | `locationd` → `fmfd` / `searchpartyd` → iCloud | the device is online |
| Offline Find My network | BLE beacon overheard by other people's Apple devices | the device is offline or off |

A sandboxed third-party iOS app receives `CLLocation` objects **from** `locationd`. There
is no API — public, or private but reachable — to change what `locationd` *emits*. iOS has
no equivalent of Android's mock location provider.

The only override that does not require a jailbreak is Apple's own developer location
simulation, and that is reached over a channel built for a **trusted host**.

On iOS 17.4+ that host can be the phone itself. The developer services sit behind an RSD
tunnel, and a device will open one to its own address. So there are two apps here, and
they differ only in how they reach that tunnel:

| | Mac app | iPhone app |
|---|---|---|
| Engine | Python, `pymobiledevice3` | Swift, `MirageKit` |
| First hop | usbmuxd, then `CoreDeviceProxy` | direct TCP to `remoted` on port 49152 |
| Credential | the lockdown pair record the Mac already holds | an Ed25519 `RpPairingFile` |
| Needs a computer | every time | once, to mint the credential |

What an on-device app cannot do is invent the host's trust. Both credentials can only be
issued by a computer the phone has genuinely paired with, and both expire. The computer
does not disappear; it moves from *present whenever you spoof* to *present when the
pairing is established or renewed*.

### The on-device path, specifically

Three details are worth writing down, because each one is a place where the obvious guess
is wrong and the failure it produces says nothing useful.

**`lockdownd` does not answer over the tunnel interface.** So the on-device path cannot
reuse the Mac's: `CoreDeviceProxy`, `TcpProvider`, and every provider-shaped API in
`idevice` are unavailable from the phone. What does answer is `remoted` on port **49152**,
speaking RemotePairing — pair-verify, then a TLS-PSK tunnel whose RSD handshake yields
exactly the same service list the USB path arrives at. Everything above RSD is shared.

**A loopback VPN is required, and not as a workaround.** `lockdownd` and `remoted` refuse
connections originating from `127.0.0.1`. A loopback VPN such as LocalDevVPN puts a `tun`
interface in the path so packets arrive with an ordinary source address, and the app is
treated like any other paired host — which, holding the credential, it is. The VPN moves
no traffic off the device.

**The credential is not the file everyone calls a pairing file.** `/var/db/lockdown`
holds a *lockdown* pair record: RSA certificates, a `HostID`, a `SystemBUID`. RemotePairing
authenticates with an Ed25519 keypair in a different file with different fields. They are
not convertible, and presenting the wrong one fails with nothing more informative than a
socket error. `native/mirage-idevice/src/bin/mirage-pair.rs` mints the right one over USB.

### The developer disk image

The DTX channel exists only while a developer disk image is mounted, and **a mount does
not survive a reboot**. On the Mac, Xcode re-mounts it and nobody notices. On the phone
there is no Xcode, so Mirage mounts it itself through `mobile_image_mounter`, which asks
Apple's signing server for a ticket bound to that specific chip.

Mirage ships no image of its own: it is Apple's software to distribute, and a personalised
ticket would not transfer between devices anyway. `scripts/prepare-phone.sh` takes the one
already installed with Xcode.

## The mechanism

Location simulation overrides `locationd` **device-wide**, and Find My reads from
`locationd`. Everything else that consumes location — Maps, Weather, Siri suggestions,
photo EXIF — follows too.

- **Before iOS 17:** the `com.apple.dt.simulatelocation` lockdown service, gated on a
  mounted DeveloperDiskImage.
- **iOS 17 and later:** RemoteXPC over an RSD tunnel, plus a personalised DDI, reached
  over the DTX channel `com.apple.instruments.server.services.LocationSimulation`.

Mirage uses [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) for the
transport. It is the mature implementation of the iOS 17+ RemoteXPC developer services;
reimplementing it would be a project in itself.

### Tunnels and privileges

There are two ways to reach the RSD, and they differ in exactly the way that matters:

| Transport | Root? | Used by Mirage |
|---|---|---|
| `NativeRemotedTunnel` — piggybacks Apple's own `remotepairingd` | **No** | **Yes**, in-process |
| `pymobiledevice3 remote tunneld` — a daemon creating a TUN interface | **Yes** | Only if already running |

Mirage opens the native tunnel **in-process**, which is what `pymobiledevice3` documents
as the path for embedders. There is no tunnel daemon to install, supervise, or elevate,
and the app runs entirely as the logged-in user.

If the native path is unavailable (a non-macOS host, or `remotepairingd` not responding),
Mirage will attach to a `tunneld` the user has chosen to run — but it never starts one
itself, because that daemon does require root.

Establishing the native tunnel can take twenty seconds or more on a first run while
`remotepairingd` discovers the device. This is normal, not a failure.

## The constraint that shapes everything

The DTX selector is `simulateLocationWithLatitude:longitude:` — **latitude and longitude,
nothing else.** Speed, course, altitude and horizontal accuracy cannot be injected; iOS
derives all of them from successive fixes.

So the only lever on realism is the *sequence* of coordinates and the timing between them.
That is why the trajectory and noise engines carry most of the weight of this project.

### Trajectory

Constant speed over a route is what makes simulated movement obvious: it takes hairpins
and motorways at the same pace and never stops at a junction. Mirage runs the standard
three-stage time-parameterisation used by motion planners:

1. Cap speed at each vertex by the local turn radius — `v = √(a_lat · R)`, with `R` from
   the circumradius of each consecutive point triple.
2. A forward pass bounding acceleration and a backward pass bounding braking, so every
   speed change is physically reachable.
3. Insert dwell time at junctions, then scale the whole profile so total elapsed time
   matches the route's expected travel time.

Step 3 is where traffic enters, and it is why Mirage needs no traffic feed of its own.
`MKDirections` returns a **traffic-aware** `expectedTravelTime` when a `departureDate` is
set. Scaling a free-flow profile to hit that number slows every segment proportionally,
which is what congestion looks like.

If the requested time is *faster* than the route can physically be driven, Mirage clamps to
the speed ceiling, re-solves the acceleration limits, and reports that the estimate was not
achievable. Silently emitting 1200 km/h would be a far louder tell than arriving late.

### Noise

A perfectly static coordinate is the single loudest sign that a location is simulated: real
GNSS never stops moving. But real drift is not white noise either — it is strongly
autocorrelated, wandering over tens of seconds as satellite geometry and multipath change.
Mirage uses an Ornstein–Uhlenbeck process, which is mean-reverting (so the position stays
near its anchor) but temporally smooth. It uses the exact discrete-time solution rather than
an Euler step, so the statistics stay correct for any tick interval.

## Approaches considered and rejected

**SDR GPS simulation** (HackRF + `gps-sdr-sim`). Broadcasting counterfeit GPS is illegal in
most jurisdictions — GNSS bands are protected, and intentional interference is a criminal
offence in many countries. It also does not reliably work: modern iPhones fuse GNSS with
Wi-Fi BSSID trilateration, cell towers and inertial dead-reckoning, so a GNSS solution that
contradicts the Wi-Fi environment is unstable or discarded outright.

**MITM of Find My traffic.** iCloud endpoints are certificate-pinned and the location
payload carries an additional end-to-end encrypted layer. Defeating the pinning needs root
on the device, at which point a direct `locationd` hook is strictly simpler.

**Jailbreak / TrollStore tweak.** A root-level hook, or the private `CLSimulationManager`
API behind a locationd-simulation entitlement. Availability keeps shrinking — checkm8
covers A11 and earlier, and there is no public persistent jailbreak for current iOS. A
legacy-hardware side path at best, never the primary product.

**Direct iCloud / Find My API.** There is no "set my location" endpoint. Position is
submitted by `fmfd`/`searchpartyd` signed with keys held in the Secure Enclave. The
reverse-engineered Find My clients that exist can *read* location reports; none can write a
device's reported position, and that asymmetry is inherent to the design.

## Components

```
┌─────────────────┐   AF_UNIX, 0600    ┌──────────────────┐   RemoteXPC/RSD   ┌────────┐
│   Mirage.app    │ ──────────────────▶│   mirage engine  │ ─────────────────▶│ iPhone │
│ SwiftUI + MapKit│   JSON lines       │  Python, async   │   DTX channel     │ locationd
└─────────────────┘                    └──────────────────┘                   └────────┘
```

| Path | Responsibility |
|---|---|
| `core/mirage/geo.py` | Spherical geometry, arc-length indexed polylines, curvature |
| `core/mirage/route.py` | Trajectory planner |
| `core/mirage/motion.py` | Ornstein–Uhlenbeck positional drift |
| `core/mirage/session.py` | Tick loop, mode state, restore-on-exit invariant |
| `core/mirage/injector.py` | DTX channel wrapper, plus a mock for device-free testing |
| `core/mirage/consent.py` | Device eligibility and the owner's consent record |
| `core/mirage/security.py` | Socket hardening, peer credential checks, log redaction |
| `core/mirage/rpc.py` | Unix-socket JSON control channel |
| `core/mirage/device.py` | Tunnel transports, device discovery, preflight errors |
| `ui/Sources/Mirage/` | The Mac app: SwiftUI, MapKit routing, engine supervision, age gate |
| `ui/Sources/MirageKit/` | The same engine in Swift, for the iPhone app — and the golden tests that hold the two in agreement |
| `ui/Sources/MirageDevice/` | `LocationInjector` over the Rust bridge |
| `ui/Sources/mirage-device-check/` | Drives a real phone from the Mac. An executable, not a test, because it moves a device |
| `native/mirage-idevice/` | Rust: the DVT transport for both platforms, and `mirage-pair` |
| `ios/` | The iPhone app and its Live Activity. The Xcode project is generated from `project.yml` |

The Mac engine is Python because `pymobiledevice3` is. The UI is Swift because native
MapKit is both the best router available on the platform and the right visual language.
They talk over a local socket rather than the UI shelling out, so the tick loop driving the
phone is never at the mercy of the UI's lifecycle.

The iPhone app has no socket and no second process: `MirageKit` is a port of the Python
maths and runs in-process, with the Rust bridge underneath it. The two engines are held to
each other by **golden tests** — `scripts/gen-golden.py` generates values from the Python,
and the Swift suite asserts against them. If they ever disagree about where a drive is at
t=100s, that fails in CI rather than on somebody's phone.

One piece is deliberately not portable: the junction-dwell model draws from Python's
Mersenne Twister, which the Swift port does not reproduce. The golden tests feed both
engines the same fixed normals and pin plans with junction stops disabled, so the
arithmetic is compared rather than the generator.

## Behavioural side effects

Overriding `locationd` is device-wide, so it is not invisible to anyone holding the phone:

1. Weather, Maps, Siri suggestions and "nearby" in every app behave as if the device is in
   the simulated location. This is the fastest giveaway.
2. Photos taken while a session is active are stamped with the simulated coordinates.
3. Significant Locations logs the simulated positions, which also corrupts genuine history.
4. Device time zone may or may not follow, and a mismatch is visible in a screenshot.
5. Developer Mode is a visible toggle in Settings, and enabling it reboots the phone.
6. If the phone goes offline, the Find My network reports its **real** position over BLE.

## Verifying on your own device

Everything above is tested against the mock injector. Whether DVT location simulation still
moves Find My on a given iOS version is an empirical question, and two tools answer it:

- `scripts/check-device.sh` — the Python engine, one precondition at a time.
- `swift run mirage-device-check --drive` — the Swift engine and the Rust transport,
  playing a real route through `MKDirections` with posted speed limits applied.

The only criterion that matters is the one they both end on: **Find My, viewed from a
second Apple ID, showing the simulated city.** The phone's own Maps proves much less.
