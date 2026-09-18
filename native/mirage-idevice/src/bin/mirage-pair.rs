//! Mint the RemotePairing credential the iPhone app needs, over USB from the Mac.
//!
//!     mirage-pair <output.plist> [udid]
//!
//! # Why this exists
//!
//! The file in `/var/db/lockdown` — the one `idevicepair` and `pymobiledevice3` deal in —
//! is a *lockdown* pair record: RSA certificates, a HostID, a SystemBUID. The on-device
//! path does not use lockdown at all. It talks to `remoted` on port 49152 over
//! RemotePairing, which authenticates with an Ed25519 keypair held in a different file
//! with different fields. The two are not convertible, and holding the wrong one produces
//! a connection that fails with nothing more useful than a socket error.
//!
//! So this pairs properly: over USB, through CoreDeviceProxy to the device's untrusted
//! tunnel service, generating a fresh keypair and running pair-setup. The result is the
//! credential the phone can later present to itself across the loopback VPN.
//!
//! This is the same thing iloader does. Mirage does it itself so that setting the app up
//! needs this repo and nothing else.

use std::io::Write as _;
use std::process::ExitCode;

use idevice::provider::IdeviceProvider;
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile};
use idevice::services::core_device_proxy::CoreDeviceProxy;
use idevice::services::rsd::RsdHandshake;
use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};
use idevice::{IdeviceService, RemoteXpcClient};

/// Must match the hostname the app pairs under, because the identifier derived from it is
/// half of what pair-verify matches against. See `PAIRING_HOSTNAME` in `lib.rs`.
const PAIRING_HOSTNAME: &str = "Mirage";

/// The device's own tunnel service, reachable without being trusted for anything else.
const TUNNEL_SERVICE: &str = "com.apple.internal.dt.coredevice.untrusted.tunnelservice";

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(output) = args.next() else {
        eprintln!("usage: mirage-pair <output.plist> [udid]");
        return ExitCode::from(2);
    };
    let udid = args.next();

    match pair(&output, udid.as_deref()).await {
        Ok(identifier) => {
            println!("   paired as {identifier}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

async fn pair(output: &str, udid: Option<&str>) -> Result<String, String> {
    let provider = usbmuxd_provider(udid).await?;

    let proxy = CoreDeviceProxy::connect(&*provider).await.map_err(|e| {
        format!(
            "could not open a tunnel to the iPhone: {e}\n\
             \n\
             Check, in order:\n\
               1. It is plugged in and unlocked, and you have tapped Trust.\n\
               2. Developer Mode is on: Settings > Privacy & Security > Developer Mode.\n\
                  Turning it on restarts the phone."
        )
    })?;

    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let adapter = proxy
        .create_software_tunnel()
        .map_err(|e| format!("could not create the software tunnel: {e}"))?;
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("could not reach RSD on port {rsd_port}: {e}"))?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD handshake failed: {e}"))?;

    let service = handshake
        .services
        .get(TUNNEL_SERVICE)
        .ok_or_else(|| format!("this iPhone does not offer {TUNNEL_SERVICE}. iOS 17.4 or later is required."))?;

    let stream = adapter
        .connect(service.port)
        .await
        .map_err(|e| format!("could not reach the tunnel service: {e}"))?;

    let mut conn = RemoteXpcClient::new(stream)
        .await
        .map_err(|e| format!("could not open RemoteXPC: {e}"))?;
    conn.do_handshake()
        .await
        .map_err(|e| format!("RemoteXPC handshake failed: {e}"))?;
    conn.recv_root()
        .await
        .map_err(|e| format!("RemoteXPC said nothing: {e}"))?;

    let mut pairing = RpPairingFile::generate(PAIRING_HOSTNAME);
    let mut client = RemotePairingClient::new(conn, PAIRING_HOSTNAME);

    client
        .connect(&mut pairing, || async { prompt_for_pin() })
        .await
        .map_err(|e| format!("pairing failed: {e}"))?;

    let identifier = pairing.identifier().to_owned();

    // 0600 from the start rather than after the fact: this is a credential, and there
    // should be no window in which it sits on disk world-readable.
    let mut file = open_private(output)?;
    file.write_all(&pairing.to_bytes())
        .map_err(|e| format!("could not write {output}: {e}"))?;
    file.sync_all()
        .map_err(|e| format!("could not flush {output}: {e}"))?;

    Ok(identifier)
}

/// Asked for only if pair-verify fails and a full pair-setup runs. Over USB with the
/// device already trusted that should not happen, so the prompt doubles as a signal that
/// something is not as expected.
fn prompt_for_pin() -> String {
    eprint!("The iPhone is showing a code. Type it here and press return: ");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    line.trim().to_owned()
}

fn open_private(path: &str) -> Result<std::fs::File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|e| format!("could not write {path}: {e}"))
}

async fn usbmuxd_provider(udid: Option<&str>) -> Result<Box<dyn IdeviceProvider>, String> {
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
            .ok_or_else(|| format!("no device with the identifier {want} is connected"))?,
        None => match devices.len() {
            0 => return Err("No iPhone found. Connect it by USB and tap Trust.".to_owned()),
            1 => &devices[0],
            n => {
                let list: Vec<&str> = devices.iter().map(|d| d.udid.as_str()).collect();
                return Err(format!(
                    "{n} devices are connected. Name one: {}",
                    list.join(", ")
                ));
            }
        },
    };

    let addr = UsbmuxdAddr::from_env_var().map_err(|e| format!("bad usbmuxd address: {e}"))?;
    Ok(Box::new(device.to_provider(addr, "mirage")))
}
