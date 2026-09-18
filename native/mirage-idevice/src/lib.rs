//! C ABI over `idevice`'s DVT location simulation.
//!
//! Exists so Swift can implement `LocationInjector` — the four-call protocol
//! (`open`/`set`/`clear`/`close`) that `DriveSession` is written against — without Swift
//! knowing anything about Rust, tunnels or RemoteXPC.
//!
//! # Which service this talks to, and why it matters
//!
//! The obvious-looking `services::simulate_location::LocationSimulationService` is
//! `com.apple.dt.simulatelocation`, the **pre-iOS-17 lockdown service**. On iOS 17+ a
//! device does not advertise it and returns `InvalidService`. This module therefore uses
//! `services::dvt::location_simulation::LocationSimulationClient`, reached over:
//!
//! ```text
//! provider -> CoreDeviceProxy -> software tunnel -> RSD handshake -> DVT -> location
//! ```
//!
//! which is the same DTX instruments channel `core/mirage/injector.py` drives through
//! `pymobiledevice3`. The two engines agree on the transport, not just the maths.
//!
//! # Two ways in, meeting at RSD
//!
//! The two platforms reach the same RemoteXPC service discovery by different routes, and
//! the difference is bigger than an address:
//!
//! * **USB** (`mirage_idevice_open`) — usbmuxd, then `CoreDeviceProxy` over lockdown.
//!   The Mac app. This is the documented host path and it needs a trusted cable.
//!
//! * **Loopback** (`mirage_idevice_open_loopback`) — a direct TCP connection to the
//!   device's own **RemotePairing** service on port 49152, reached through the `tun`
//!   interface a loopback VPN such as LocalDevVPN provides. The iPhone app.
//!
//! The loopback case is not the USB case with a different first hop, which is what it
//! looks like and what this file originally assumed. `lockdownd` does not answer on the
//! tun interface at all, so `CoreDeviceProxy` — and every provider-shaped API in the
//! crate — is unavailable on-device. What does answer is `remoted` on 49152, speaking
//! RemotePairing: pair-verify against an Ed25519 credential, then a TLS-PSK tunnel whose
//! RSD handshake gives exactly the same service list the USB path ends at.
//!
//! One consequence worth stating plainly, because it changes setup: the credential is a
//! **`RpPairingFile`**, not the lockdown pair record in `/var/db/lockdown`. Different
//! format, different keys, not convertible. `scripts/prepare-phone.sh` mints one with
//! the `mirage-pair` binary in this crate. See `docs/ARCHITECTURE.md`.
//!
//! # Why a thread and a channel
//!
//! The chain borrows down its whole length: the location client borrows the DVT client,
//! which borrows the tunnel handle, which borrows the adapter. That is self-referential
//! and cannot be stored in a struct. So the chain is built inside one async task and
//! stays on its stack for the life of the connection; commands arrive over a channel and
//! replies go back over a one-shot. This also means every call is naturally serialised
//! against one connection, which is what the device wants anyway.
//!
//! # Memory
//!
//! Every fallible call takes an `out_error: *mut *mut c_char`. On failure it is set to a
//! freshly allocated, NUL-terminated message the caller must release with
//! [`mirage_idevice_string_free`]. On success it is left untouched.

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::mpsc::{sync_channel, SyncSender};

pub const MIRAGE_OK: c_int = 0;
pub const MIRAGE_ERR: c_int = -1;

type Reply = SyncSender<Result<(), String>>;

enum Command {
    Set { lat: f64, lon: f64, reply: Reply },
    Clear { reply: Reply },
}

/// How to reach the device. Everything downstream of this is shared.
enum Target {
    /// usbmuxd, optionally naming a device. The Mac.
    Usb { udid: Option<String> },
    /// The device's own RemotePairing service, reached across the loopback VPN.
    Loopback {
        address: String,
        pairing_file: PathBuf,
        /// A folder holding Image.dmg, its .trustcache and BuildManifest.plist. When
        /// present, Mirage mounts the developer disk image itself if the device has none —
        /// which is what makes the phone independent of the Mac after a reboot.
        ddi: Option<PathBuf>,
    },
}

/// Opaque to C. Owns the worker thread and the channel into it.
pub struct MirageDevice {
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
    worker: Option<std::thread::JoinHandle<()>>,
}

fn set_error(out_error: *mut *mut c_char, message: impl AsRef<str>) {
    if out_error.is_null() {
        return;
    }
    let owned = CString::new(message.as_ref())
        .unwrap_or_else(|_| CString::new("error message contained a NUL byte").unwrap());
    unsafe { *out_error = owned.into_raw() };
}

/// Release a message produced by any call in this library.
///
/// # Safety
/// `s` must have come from this library and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn mirage_idevice_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Borrow a C string as `Option<String>`, NULL becoming `None`.
unsafe fn optional_string(
    raw: *const c_char,
    what: &str,
    out_error: *mut *mut c_char,
) -> Result<Option<String>, ()> {
    if raw.is_null() {
        return Ok(None);
    }
    match CStr::from_ptr(raw).to_str() {
        Ok(s) => Ok(Some(s.to_owned())),
        Err(e) => {
            set_error(out_error, format!("{what} was not valid UTF-8: {e}"));
            Err(())
        }
    }
}

/// Spawn the worker and block until it has either connected or given up.
fn start(target: Target, out_error: *mut *mut c_char) -> *mut MirageDevice {
    let (commands, command_rx) = tokio::sync::mpsc::unbounded_channel::<Command>();
    let (ready_tx, ready_rx) = sync_channel::<Result<(), String>>(0);

    let worker = std::thread::Builder::new()
        .name("mirage-idevice".into())
        .spawn(move || worker_main(target, command_rx, ready_tx));

    let worker = match worker {
        Ok(w) => w,
        Err(e) => {
            set_error(out_error, format!("could not start the device thread: {e}"));
            return ptr::null_mut();
        }
    };

    match ready_rx.recv() {
        Ok(Ok(())) => Box::into_raw(Box::new(MirageDevice {
            commands,
            worker: Some(worker),
        })),
        Ok(Err(message)) => {
            set_error(out_error, message);
            let _ = worker.join();
            ptr::null_mut()
        }
        Err(_) => {
            set_error(out_error, "the device thread stopped before reporting");
            let _ = worker.join();
            ptr::null_mut()
        }
    }
}

/// Connect over USB and open the location-simulation channel.
///
/// `udid` may be NULL to take the only device present. Returns NULL on failure with
/// `out_error` set. Blocks until the tunnel is up, which on a first run can take a while.
///
/// # Safety
/// `udid`, when non-NULL, must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn mirage_idevice_open(
    udid: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut MirageDevice {
    let udid = match optional_string(udid, "udid", out_error) {
        Ok(v) => v,
        Err(()) => return ptr::null_mut(),
    };
    start(Target::Usb { udid }, out_error)
}

/// Connect to a device over TCP using a pairing file, and open the location-simulation
/// channel.
///
/// On the iPhone this is how Mirage reaches *itself*: `address` is the peer address of a
/// loopback VPN (LocalDevVPN hands out `10.7.0.1`), and `pairing_file_path` points at the
/// pairing file imported during setup.
///
/// `ddi_dir`, when non-NULL, is a folder containing a developer disk image — an
/// `Image.dmg`, a `*.trustcache` and a `BuildManifest.plist`. If the device has no image
/// mounted, Mirage mounts this one before opening the channel. Without it the phone needs
/// a Mac again after every reboot, because a mounted image does not survive one.
///
/// # Safety
/// `address` and `pairing_file_path` must be valid NUL-terminated C strings. `ddi_dir`
/// must be one or NULL.
#[no_mangle]
pub unsafe extern "C" fn mirage_idevice_open_loopback(
    address: *const c_char,
    pairing_file_path: *const c_char,
    ddi_dir: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut MirageDevice {
    let address = match optional_string(address, "address", out_error) {
        Ok(Some(v)) => v,
        Ok(None) => {
            set_error(out_error, "no address given");
            return ptr::null_mut();
        }
        Err(()) => return ptr::null_mut(),
    };
    let pairing_file = match optional_string(pairing_file_path, "pairing file path", out_error) {
        Ok(Some(v)) => PathBuf::from(v),
        Ok(None) => {
            set_error(out_error, "no pairing file given");
            return ptr::null_mut();
        }
        Err(()) => return ptr::null_mut(),
    };
    let ddi = match optional_string(ddi_dir, "developer disk image folder", out_error) {
        Ok(v) => v.map(PathBuf::from),
        Err(()) => return ptr::null_mut(),
    };

    start(
        Target::Loopback {
            address,
            pairing_file,
            ddi,
        },
        out_error,
    )
}

fn dispatch(
    handle: *mut MirageDevice,
    out_error: *mut *mut c_char,
    make: impl FnOnce(Reply) -> Command,
) -> c_int {
    let device = match unsafe { handle.as_ref() } {
        Some(d) => d,
        None => {
            set_error(out_error, "no device handle");
            return MIRAGE_ERR;
        }
    };

    let (reply_tx, reply_rx) = sync_channel::<Result<(), String>>(0);
    if device.commands.send(make(reply_tx)).is_err() {
        set_error(out_error, "the connection to the iPhone has gone away");
        return MIRAGE_ERR;
    }

    match reply_rx.recv() {
        Ok(Ok(())) => MIRAGE_OK,
        Ok(Err(message)) => {
            set_error(out_error, message);
            MIRAGE_ERR
        }
        Err(_) => {
            set_error(out_error, "the connection to the iPhone has gone away");
            MIRAGE_ERR
        }
    }
}

/// Set the simulated location.
///
/// # Safety
/// `handle` must have come from an open call and not yet been closed.
#[no_mangle]
pub unsafe extern "C" fn mirage_idevice_set(
    handle: *mut MirageDevice,
    latitude: f64,
    longitude: f64,
    out_error: *mut *mut c_char,
) -> c_int {
    if !latitude.is_finite() || !longitude.is_finite() {
        set_error(out_error, "latitude and longitude must be finite");
        return MIRAGE_ERR;
    }
    if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
        set_error(out_error, "coordinates out of range");
        return MIRAGE_ERR;
    }
    dispatch(handle, out_error, |reply| Command::Set {
        lat: latitude,
        lon: longitude,
        reply,
    })
}

/// Clear any simulated location.
///
/// Clearing when nothing is simulated is a no-op on the device, so this is always safe to
/// call — which is what lets Swift's `restore()` run unconditionally.
///
/// # Safety
/// `handle` must have come from an open call and not yet been closed.
#[no_mangle]
pub unsafe extern "C" fn mirage_idevice_clear(
    handle: *mut MirageDevice,
    out_error: *mut *mut c_char,
) -> c_int {
    dispatch(handle, out_error, |reply| Command::Clear { reply })
}

/// Close the connection and release the handle.
///
/// Deliberately does **not** clear the location. A simulated position outliving the
/// process is the documented behaviour on every platform Mirage runs on, and undoing it
/// silently on teardown would hide the one state the user most needs to know about.
///
/// # Safety
/// `handle` must have come from an open call, and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn mirage_idevice_close(handle: *mut MirageDevice) {
    if handle.is_null() {
        return;
    }
    let mut device = Box::from_raw(handle);
    // Dropping the sender ends the worker's command loop, which unwinds the tunnel.
    let MirageDevice { commands, worker } = &mut *device;
    drop(std::mem::replace(
        commands,
        tokio::sync::mpsc::unbounded_channel().0,
    ));
    if let Some(worker) = worker.take() {
        let _ = worker.join();
    }
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

/// The RemotePairing service on the device. Not lockdown's 62078 — a different service
/// speaking a different protocol, and the only one that answers over the tun interface.
const REMOTE_PAIRING_PORT: u16 = 49152;

/// What this host calls itself when pairing. Stable, because the identifier derived from
/// it is half of what pair-verify matches against.
const PAIRING_HOSTNAME: &str = "Mirage";

fn worker_main(
    target: Target,
    commands: tokio::sync::mpsc::UnboundedReceiver<Command>,
    ready: SyncSender<Result<(), String>>,
) {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            let _ = ready.send(Err(format!("could not start the async runtime: {e}")));
            return;
        }
    };

    runtime.block_on(async move {
        match target {
            Target::Usb { udid } => run_usb(udid, commands, ready).await,
            Target::Loopback {
                address,
                pairing_file,
                ddi,
            } => run_loopback(address, pairing_file, ddi, commands, ready).await,
        }
    });
}

/// Hand out fixes until the caller drops the channel.
///
/// Shared by both transports because it is the only part of them that is the same. Every
/// call is serialised against one connection here, which is what the device wants anyway.
async fn serve<R: idevice::ReadWrite>(
    location: &mut idevice::services::dvt::location_simulation::LocationSimulationClient<'_, R>,
    commands: &mut tokio::sync::mpsc::UnboundedReceiver<Command>,
) {
    while let Some(command) = commands.recv().await {
        match command {
            Command::Set { lat, lon, reply } => {
                let result = location
                    .set(lat, lon)
                    .await
                    .map_err(|e| format!("could not set the location: {e}"));
                let _ = reply.send(result);
            }
            Command::Clear { reply } => {
                let result = location
                    .clear()
                    .await
                    .map_err(|e| format!("could not clear the location: {e}"));
                let _ = reply.send(result);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// USB: the Mac
// ---------------------------------------------------------------------------

/// usbmuxd → CoreDeviceProxy → software tunnel → RSD → DVT → location.
///
/// Everything below borrows the step above it, so the whole chain stays on this stack for
/// the life of the connection. That is why this is a function and not a struct.
async fn run_usb(
    udid: Option<String>,
    mut commands: tokio::sync::mpsc::UnboundedReceiver<Command>,
    ready: SyncSender<Result<(), String>>,
) {
    use idevice::{
        provider::{IdeviceProvider, RsdProvider},
        services::{
            core_device_proxy::CoreDeviceProxy,
            dvt::{location_simulation::LocationSimulationClient, remote_server::RemoteServerClient},
            rsd::RsdHandshake,
        },
        IdeviceService, ReadWrite,
    };

    macro_rules! give_up {
        ($($arg:tt)*) => {{
            let _ = ready.send(Err(format!($($arg)*)));
            return;
        }};
    }

    let provider: Box<dyn IdeviceProvider> = match usbmuxd_provider(udid.as_deref()).await {
        Ok(p) => p,
        Err(message) => give_up!("{message}"),
    };

    let proxy = match tokio::time::timeout(
        std::time::Duration::from_secs(30),
        CoreDeviceProxy::connect(&*provider),
    )
    .await
    {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => give_up!(
            "could not open the device tunnel: {e}. \
             Enable Developer Mode (Settings > Privacy & Security > Developer Mode), \
             reboot the iPhone, and reconnect."
        ),
        Err(_) => give_up!("timed out opening the device tunnel after 30s. Unplug and replug the iPhone."),
    };

    let rsd_port = proxy.tunnel_info().server_rsd_port;

    let adapter = match proxy.create_software_tunnel() {
        Ok(a) => a,
        Err(e) => give_up!("could not create the software tunnel: {e}"),
    };
    let mut handle = adapter.to_async_handle();

    let rsd_stream = match handle.connect_to_service_port(rsd_port).await {
        Ok(s) => s,
        Err(e) => give_up!("could not reach RSD on port {rsd_port}: {e}"),
    };

    let mut handshake = match RsdHandshake::new(rsd_stream).await {
        Ok(h) => h,
        Err(e) => give_up!("RSD handshake failed: {e}"),
    };

    let mut dvt = match handshake
        .connect::<RemoteServerClient<Box<dyn ReadWrite>>>(&mut handle)
        .await
    {
        Ok(d) => d,
        Err(e) => give_up!(
            "could not open the developer-tools channel: {e}. \
             This usually means no developer disk image is mounted; opening the device \
             once in Xcode mounts one."
        ),
    };

    let mut location = match LocationSimulationClient::new(&mut dvt).await {
        Ok(l) => l,
        Err(e) => give_up!("could not open location simulation: {e}"),
    };

    if ready.send(Ok(())).is_err() {
        return; // caller gave up
    }
    serve(&mut location, &mut commands).await;
}

/// The one owned, returnable part of the USB chain.
async fn usbmuxd_provider(
    udid: Option<&str>,
) -> Result<Box<dyn idevice::provider::IdeviceProvider>, String> {
    use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};

    let mut usbmuxd = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("cannot reach usbmuxd: {e}. Is the iPhone plugged in?"))?;

    let devices = usbmuxd
        .get_devices()
        .await
        .map_err(|e| format!("cannot list devices: {e}"))?;

    let device = match udid {
        Some(want) => devices
            .iter()
            .find(|d| d.udid == want)
            .ok_or_else(|| "no device with that identifier is connected".to_owned())?,
        None => match devices.len() {
            0 => {
                return Err(
                    "No iPhone found. Connect it by USB and tap Trust on the device.".to_owned(),
                )
            }
            1 => &devices[0],
            n => return Err(format!("{n} devices are connected; specify which one")),
        },
    };

    let addr = UsbmuxdAddr::from_env_var().map_err(|e| format!("bad usbmuxd address: {e}"))?;
    Ok(Box::new(device.to_provider(addr, "mirage")))
}

// ---------------------------------------------------------------------------
// Loopback: the phone, talking to itself
// ---------------------------------------------------------------------------

/// TCP 49152 → RemotePairing → TLS-PSK tunnel → RSD → (disk image) → DVT → location.
async fn run_loopback(
    address: String,
    pairing_file: PathBuf,
    ddi: Option<PathBuf>,
    mut commands: tokio::sync::mpsc::UnboundedReceiver<Command>,
    ready: SyncSender<Result<(), String>>,
) {
    use idevice::{
        services::dvt::{
            location_simulation::LocationSimulationClient, remote_server::RemoteServerClient,
        },
        ReadWrite, RsdService,
    };

    macro_rules! give_up {
        ($($arg:tt)*) => {{
            let _ = ready.send(Err(format!($($arg)*)));
            return;
        }};
    }

    let (mut adapter, mut handshake) = match open_tunnel(&address, &pairing_file).await {
        Ok(pair) => pair,
        Err(message) => give_up!("{message}"),
    };

    // The developer-tools channel exists only while a disk image is mounted, and a mount
    // does not survive a reboot. On the Mac, Xcode re-mounts it and nobody notices; here
    // Mirage has to, or the phone needs the cable back after every restart.
    if let Err(message) = ensure_developer_image(&mut adapter, &mut handshake, ddi.as_deref()).await
    {
        give_up!("{message}");
    }

    let mut dvt = match RemoteServerClient::<Box<dyn ReadWrite>>::connect_rsd(
        &mut adapter,
        &mut handshake,
    )
    .await
    {
        Ok(d) => d,
        Err(e) => give_up!(
            "could not open the developer-tools channel: {e}. \
             This usually means no developer disk image is mounted."
        ),
    };

    // The server sends an unsolicited message on connect. Leaving it in the buffer makes
    // the first real reply arrive one message out of step.
    if let Err(e) = dvt.read_message(0).await {
        give_up!("the developer-tools channel did not greet us: {e}");
    }

    let mut location = match LocationSimulationClient::new(&mut dvt).await {
        Ok(l) => l,
        Err(e) => give_up!("could not open location simulation: {e}"),
    };

    if ready.send(Ok(())).is_err() {
        return;
    }
    serve(&mut location, &mut commands).await;
}

/// Pair-verify against the device and bring up the tunnel it offers.
///
/// Mirrors what `tunnel_create_rppairing` does in idevice's own C API, which is the path
/// every on-device tool takes. `connect` tries pair-verify first and falls back to a full
/// pair-setup — which would need the PIN the device displays, and which should never
/// happen here because `mirage-pair` already did it from the Mac.
async fn open_tunnel(
    address: &str,
    pairing_file: &Path,
) -> Result<
    (
        idevice::tcp::handle::AdapterHandle,
        idevice::services::rsd::RsdHandshake,
    ),
    String,
> {
    use idevice::remote_pairing::{
        connect_tls_psk_tunnel_native, RemotePairingClient, RpPairingFile, RpPairingSocket,
    };
    use idevice::services::rsd::RsdHandshake;
    use idevice::tcp::adapter::Adapter;

    let ip: std::net::IpAddr = address
        .parse()
        .map_err(|_| format!("{address} is not an IP address"))?;
    let socket_addr = std::net::SocketAddr::new(ip, REMOTE_PAIRING_PORT);

    let mut rpf = RpPairingFile::read_from_file(pairing_file).await.map_err(|e| {
        format!(
            "could not read the pairing file: {e}. \
             Run ./scripts/prepare-phone.sh on the Mac and import the folder again."
        )
    })?;

    let stream = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::net::TcpStream::connect(socket_addr),
    )
    .await
    .map_err(|_| format!("nothing answered at {socket_addr} within 10s"))?
    .map_err(|e| format!("could not connect to {socket_addr}: {e}"))?;

    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), PAIRING_HOSTNAME);
    rpc.connect(&mut rpf, || async { String::new() })
        .await
        .map_err(|e| {
            format!(
                "the iPhone would not accept the pairing file: {e}. \
                 Pairing files expire — re-run ./scripts/prepare-phone.sh."
            )
        })?;

    // The tunnel is a second connection, to a port the device allocates for it.
    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| format!("the iPhone would not open a tunnel: {e}"))?;
    let mut tunnel_addr = socket_addr;
    tunnel_addr.set_port(tunnel_port);

    let tunnel_stream = tokio::net::TcpStream::connect(tunnel_addr)
        .await
        .map_err(|e| format!("could not reach the tunnel on {tunnel_addr}: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|e| format!("the tunnel handshake failed: {e}"))?;

    let client_ip: std::net::IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("the tunnel reported an unreadable client address: {e}"))?;
    let server_ip: std::net::IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("the tunnel reported an unreadable server address: {e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    // A userspace TCP stack over the tunnel. The 60 bytes are IP and TCP headers, which
    // the stack adds on top of whatever we hand it.
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("could not reach RSD on port {rsd_port}: {e}"))?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD handshake failed: {e}"))?;

    Ok((adapter, handshake))
}

// ---------------------------------------------------------------------------
// Developer disk image
// ---------------------------------------------------------------------------

/// Make sure the device has a developer disk image mounted, mounting one if it does not.
///
/// `mount_personalized_rsd` asks Apple's signing server for a ticket bound to this
/// specific chip, so an image cannot be copied between devices — which is also why Mirage
/// ships none of its own and asks for Xcode's.
async fn ensure_developer_image(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::services::rsd::RsdHandshake,
    ddi: Option<&Path>,
) -> Result<(), String> {
    use idevice::services::mobile_image_mounter::ImageMounter;
    use idevice::RsdService;

    let mut mounter = ImageMounter::connect_rsd(adapter, handshake)
        .await
        .map_err(|e| format!("could not reach the image mounter: {e}"))?;

    match mounter.query_developer_mode_status().await {
        Ok(true) => {}
        Ok(false) => {
            return Err("Developer Mode is off. Settings > Privacy & Security > Developer Mode. \
                        Turning it on restarts the iPhone."
                .to_owned())
        }
        // Not every device answers this. Not a reason to stop.
        Err(_) => {}
    }

    if let Ok(mounted) = mounter.copy_devices().await {
        if !mounted.is_empty() {
            return Ok(());
        }
    }

    let Some(dir) = ddi else {
        return Err("No developer disk image is mounted, and Mirage has none to mount. \
                    Run ./scripts/prepare-phone.sh and import the whole folder in Setup. \
                    A mounted image is lost when the iPhone restarts."
            .to_owned());
    };

    let bundle = DdiBundle::find(dir)?;
    let chip_id = unique_chip_id(adapter, handshake).await?;

    mounter
        .mount_personalized_rsd(
            adapter,
            handshake,
            bundle.image,
            bundle.trust_cache,
            &bundle.build_manifest,
            None,
            chip_id,
        )
        .await
        .map_err(|e| {
            format!(
                "could not mount the developer disk image: {e}. \
                 Check that it matches this iPhone's iOS version, and that the phone is \
                 online — signing the image needs Apple's server."
            )
        })
}

struct DdiBundle {
    image: Vec<u8>,
    trust_cache: Vec<u8>,
    build_manifest: Vec<u8>,
}

impl DdiBundle {
    /// `prepare-phone.sh` writes these under fixed names, having worked out which of
    /// Xcode's files is which from the build manifest.
    fn find(dir: &Path) -> Result<Self, String> {
        let entries = std::fs::read_dir(dir)
            .map_err(|e| format!("could not read {}: {e}", dir.display()))?;

        let (mut image, mut trust_cache, mut manifest) = (None, None, None);
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_lowercase();
            if name.ends_with(".trustcache") {
                trust_cache = Some(path);
            } else if name.ends_with(".dmg") {
                image = Some(path);
            } else if name == "buildmanifest.plist" {
                manifest = Some(path);
            }
        }

        let missing = |what: &str| {
            format!(
                "{} has no {what}. A developer disk image folder needs Image.dmg, \
                 its .trustcache and BuildManifest.plist.",
                dir.display()
            )
        };

        let read = |path: PathBuf| {
            std::fs::read(&path).map_err(|e| format!("could not read {}: {e}", path.display()))
        };

        Ok(Self {
            image: read(image.ok_or_else(|| missing("disk image"))?)?,
            trust_cache: read(trust_cache.ok_or_else(|| missing("trust cache"))?)?,
            build_manifest: read(manifest.ok_or_else(|| missing("BuildManifest.plist"))?)?,
        })
    }
}

/// The chip identifier the signing ticket is bound to.
async fn unique_chip_id(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::services::rsd::RsdHandshake,
) -> Result<u64, String> {
    use idevice::services::lockdown::LockdownClient;
    use idevice::RsdService;

    // Lockdown over RSD needs no session: the tunnel is already authenticated, which is
    // the whole point of having pair-verified to get it.
    let mut lockdown = LockdownClient::connect_rsd(adapter, handshake)
        .await
        .map_err(|e| format!("could not reach lockdown: {e}"))?;

    let value = lockdown
        .get_value(Some("UniqueChipID"), None)
        .await
        .map_err(|e| format!("could not read the chip identifier: {e}"))?;

    value
        .as_unsigned_integer()
        .or_else(|| value.as_signed_integer().map(|v| v as u64))
        .ok_or_else(|| "the device reported an unreadable chip identifier".to_owned())
}
