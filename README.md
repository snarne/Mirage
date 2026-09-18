# Mirage

Simulate your iPhone's location, with traffic-aware route playback. There is an iPhone app
and a Mac app; they share one engine.

Mirage changes the position your iPhone reports to iOS itself — so Find My, and everyone
you share your location with, sees the simulated position. Routes are planned with MapKit,
held to the posted speed limit of the street the car is actually on, and replayed as a
physically plausible drive rather than a dot teleporting along a line.

No jailbreak, no paid developer account, no subscription, and nothing to buy.

```
      you pick a place                 the engine                    your iPhone
   ┌──────────────────┐        ┌───────────────────────┐        ┌──────────────────┐
   │ MapKit route +   │ ─────▶ │ timed trajectory,     │ ─────▶ │ locationd        │
   │ traffic estimate │        │ speed limits, drift   │        │ → Find My        │
   └──────────────────┘        └───────────────────────┘        └──────────────────┘
```

---

## Which one do you want?

**The iPhone app** is the one most people want. It needs a Mac once, to set up, and then
not again — you can leave the house with it.

**The Mac app** drives a tethered or Wi-Fi-paired iPhone from the desktop. It needs the
Mac awake and reachable the whole time.

Both do the same thing to the phone. The rest of this README covers the iPhone app; the
Mac app is [further down](#the-mac-app).

---

## What you need

- An iPhone you own, running **iOS 17.4 or later**
- A Mac with **Xcode** installed
- An **Apple ID**. A free one is enough — it signs the app for seven days at a time, and
  re-signing costs nothing but a rebuild
- The **Rust toolchain**: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **[LocalDevVPN](https://apps.apple.com/app/id6746180840)** on the iPhone — free, and the
  only other app involved

That is the whole list. No sideloader, no paid developer programme, and no second helper
app beyond the VPN.

<details>
<summary><b>Why a VPN is in that list</b></summary>

Mirage reaches your iPhone's own developer service the same way a computer would. iOS
refuses that connection when it comes from `127.0.0.1`, so it has to arrive through a
network interface. A loopback VPN provides one. It moves no traffic off your phone and
talks to nothing on the internet — it exists purely so the packets come back with an
ordinary source address.

Mirage cannot provide that interface itself: doing so needs Apple's Network Extension
entitlement, which is not available to free Apple IDs. That single restriction is the only
reason this is two apps instead of one.
</details>

---

## Setting it up

### 1. Get the code

```bash
git clone https://github.com/snarne/Mirage.git
cd Mirage
```

### 2. Build it onto the phone

```bash
./scripts/gen-xcodeproj.sh
open ios/Mirage.xcodeproj
```

The script installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) through Homebrew if
you do not have it, builds the Rust bridge for the phone, and writes the Xcode project.
The project is generated rather than committed — it is a pile of UUIDs that conflicts on
every merge, and everyone who builds this signs it with their own identity anyway.

In Xcode, once:

1. Select the **Mirage** target → **Signing & Capabilities** → **Team** → your Apple ID.
2. Do the same for the **MirageWidgets** target.
3. Pick your iPhone at the top and press Run.

If the bundle identifier is already taken, choose your own:

```bash
BUNDLE_ID_PREFIX=com.yourname.mirage ./scripts/gen-xcodeproj.sh
```

You can also save yourself a step later by passing your Team ID, which is in
**Xcode → Settings → Accounts → your Apple ID**, ten characters:

```bash
DEVELOPMENT_TEAM=A1B2C3D4E5 ./scripts/gen-xcodeproj.sh
```

### 3. On the phone

- **Developer Mode** on: Settings → Privacy & Security → Developer Mode. Switching it on
  restarts the phone.
- **LocalDevVPN** connected. Check for the VPN badge in the status bar, not just that the
  app is open.

### 4. Give Mirage its credentials

```bash
./scripts/prepare-phone.sh
```

Plug the iPhone in, unlocked. This writes a folder to your Desktop with two things in it:

| | What it is | Why it is needed |
|---|---|---|
| `pairing.plist` | A RemotePairing credential, minted over USB | Your iPhone will not talk to anything that cannot present one. This is the security boundary, and Mirage does not try to get around it |
| `Image.dmg`, its trust cache and `BuildManifest.plist` | Apple's developer disk image, taken from your Xcode | The developer service Mirage drives only exists while one is mounted, and a mount is lost on reboot. Mirage re-mounts it itself so the Mac is not needed again |

AirDrop the folder to the iPhone. Files will hand you a zip — tap it to uncompress. Then
in Mirage: **Setup → Choose the folder…**, pick the uncompressed folder, and tick the
acknowledgement.

**Then delete the folder from your Mac.** A pairing file is a key to your phone.

Mirage ships no disk image of its own. Redistributing Apple's software is not something an
MIT-licensed project should do, and the image is personalised to your chip when it mounts
anyway.

---

## Using it

Tap the map to drop a pin, or search for a place.

**Hold a location.** One pin, then **Hold here**. Your iPhone reports that position,
drifting naturally rather than sitting perfectly still — a coordinate that never moves at
all is the loudest tell there is.

**Drive a route.** Two or more places, then **Drive**. The first is where the drive starts,
the last is the destination, and anything between is a stop with its own dwell time.
Mirage plans through them with MapKit, pulls posted speed limits from OpenStreetMap, and
plays the route at speeds those streets allow — slowing into corners, sitting a few mph
over the limit on a clear road, and not speeding at all in a queue.

Put the phone in your pocket. The drive continues in the background and while the phone is
locked; that is what the Live Activity on the Lock Screen is holding open, and **Restore**
is right there on it so you never have to open the app to stop.

iOS shows the blue location indicator for the whole session. Mirage does not hide that:
the app genuinely holds a background location session, and an indicator saying so is
correct.

**Units** follow your region by default and can be set either way in Settings. The engine
works in metres per second regardless; only what you read changes.

---

## What it costs to keep running

- **Seven days.** A free Apple ID signs an app for a week. Rebuild from Xcode and the week
  starts again. Nothing inside Mirage expires when the signature does — your trips,
  settings and imported credentials are all still there.
- **The VPN has to be on** whenever you start a session.
- **The pairing file expires**, in weeks rather than days. Re-run `prepare-phone.sh` and
  import again.

---

## When it will not connect

Mirage names the cause rather than saying "failed". In rough order of likelihood:

| What it says | What to do |
|---|---|
| Nothing answered at 10.7.0.1 | Turn the VPN on. Check the address in Mirage's Settings matches the **Device IP** LocalDevVPN shows. Check Settings → Mirage → **Local Network** is on — without it iOS refuses the connection before it leaves the app |
| The pairing file was not accepted | It expired. Re-run `prepare-phone.sh` and import again |
| Developer Mode is off | Settings → Privacy & Security → Developer Mode |
| No developer disk image is mounted | Import the whole setup folder, not just the pairing file |

---

## What happens when

A simulated location lives in `locationd` on the phone. Mirage sends it there; it does not
hold it up. So it survives almost everything.

| Situation | What the phone does | What Mirage does |
|---|---|---|
| You close Mirage | Keeps reporting the simulated location | Nothing. The Live Activity stays on the Lock Screen |
| Mirage crashes | Keeps reporting it | Says so on reopening, with Restore. It never clears behind your back |
| The connection drops mid-drive | Freezes at the last fix it received | The drive keeps running on the clock |
| It reconnects | Jumps to where you would be by now | Resumes delivering. No rewind, no replay of the gap |
| The drive arrives | Reports the destination with natural drift | Holds it indefinitely |
| Session length elapses | Keeps reporting where it had got to | Stops advancing, tells you, restores nothing |
| You press Restore | Back to real GPS | Reopens the connection first if it had died |
| Nothing at all | Stays simulated indefinitely | — |

The one thing that clears a location without Mirage is **rebooting the iPhone**.

Mirage cannot ask your phone whether it is simulating — the interface only writes, never
reads. So it keeps its own durable record instead: written when a position is actually
delivered, cleared only when a stop is confirmed. It survives crashes and restarts. While
that record says a location is set, the app shows a banner **you cannot dismiss**, with a
Restore button. It goes when the location is genuinely restored, and not before.

Two consequences worth knowing:

- **Set a location, put the phone away, forget, and you stay there.** That is the intended
  behaviour — it is what lets you walk off with it — but nothing will undo it for you.
- **Anything that stops Mirage delivering leaves a perfectly static coordinate.** While
  running, Mirage re-sends about once a second with realistic drift.

---

## Your data

Mirage has no account, no server, no analytics and no network calls except to Apple (for
routing and to sign the disk image) and OpenStreetMap (for speed limits).

Your pairing file, the disk image, your saved trips and your settings live inside the
app's own container on the phone. They are excluded from iCloud backups, protected at
rest, discarded when the app version changes, and gone when you delete the app. There is a
**Remove everything Mirage has stored** button in Settings so you do not have to delete
the app to be sure — or trust that deleting it did the job.

**Mirage never asks for an Apple ID or iCloud password.** It works at the device level over
a pairing you already trust, and there is no code path in this project that accepts one.

---

## What this does not hide

Simulation is device-wide and is not invisible:

- Weather, Maps, Siri suggestions and photo EXIF all follow the simulated location
- Significant Locations logs it, which also corrupts your genuine history
- If the phone goes offline, the Find My network reports its **real** position over BLE —
  spoofing covers only the self-reported channel

---

## The Mac app

Drives a tethered or Wi-Fi-paired iPhone, with the same routing and the same safety model.
It does not need the Rust toolchain or the VPN.

```bash
./scripts/bootstrap.sh     # creates the Python environment
./scripts/build_app.sh     # builds Mirage.app
open build/Mirage.app
```

The app starts and supervises the engine itself — no separate terminal step, and nothing
asks for your password. Plug the iPhone in once to pair it and enable Developer Mode;
after that it works over Wi-Fi on the same network. First launch can take twenty seconds
or so while the tunnel is established.

Ad-hoc signing is enough to run it, but Apple will not serve Apple Account age data to a
binary with no Team Identifier. To enable that path:

```bash
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: You (TEAMID)" ./scripts/build_app.sh
```

Mirage refuses to run on a device someone else manages. Before any session it checks
whether the iPhone is supervised, MDM-enrolled or carrying a parental-restriction profile,
and stops there if so — no consent overrides that. It then requires an age attestation; on
macOS 26+ that uses Apple's `DeclaredAgeRange`, which answers from your Apple Account
rather than a checkbox. Mirage never sees your date of birth.

---

## Tests

The mock injector exercises the whole stack, so none of this needs a device:

```bash
./scripts/build-native.sh                       # the Rust bridge, once
cd core && ../.venv/bin/python -m pytest -q     # the Python engine
cd ui   && swift test                           # the Swift engine and the apps' core
```

107 tests in the Python engine, 77 in Swift. The Swift suite includes **cross-engine
golden tests**: the Python is the reference implementation, `MirageKit` is a port of it,
and the values are asserted against output generated from the Python by
`./scripts/gen-golden.py`. Regenerate after any deliberate change to the maths and expect
the Swift suite to fail until the port is brought back into line — that failure is the
point.

To check the mechanism still works on a given iOS version, which is an empirical question
Apple has changed the answer to before:

```bash
./scripts/check-device.sh                       # the Python engine, step by step
cd ui && swift run mirage-device-check --drive  # the Swift engine, driving a real route
```

Both end on the only result that counts: **Find My, viewed from a second Apple ID,
showing the simulated city.**

---

## How it works

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the mechanism, the two transports, why the
VPN and the disk image are needed, and the approaches that were considered and rejected.

[docs/SECURITY.md](docs/SECURITY.md) — the threat model, the redaction rules, and an honest
account of what the controls do and do not resist.

---

## Legitimate use

Testing location-dependent features, privacy from unwanted tracking, and research are the
reasons this exists. Using it to defeat court-ordered monitoring, to deceive an employer on
a company-owned device, or to misrepresent location for legal or insurance purposes is a
different activity with real consequences. Mirage's device checks refuse the managed-device
case outright; the rest is on you.

## License

MIT — see [LICENSE](LICENSE).
