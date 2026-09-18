/*
 * mirage_idevice — C ABI over idevice's DVT location simulation.
 *
 * Swift consumes this through the CMirageIdevice system-library target and wraps it as a
 * LocationInjector, the four-call protocol DriveSession is written against.
 *
 * Every fallible call takes an out_error. On failure it is set to a NUL-terminated message
 * the caller must release with mirage_idevice_string_free. On success it is untouched, so
 * initialise it to NULL and check it only when the call reports failure.
 *
 * These calls block. Do not make them on a thread you care about.
 */

#ifndef MIRAGE_IDEVICE_H
#define MIRAGE_IDEVICE_H

#ifdef __cplusplus
extern "C" {
#endif

#define MIRAGE_OK 0
#define MIRAGE_ERR (-1)

/* Opaque. Owns the connection and its runtime. */
typedef struct MirageDevice MirageDevice;

/*
 * Connect over USB and open the location-simulation service.
 * udid may be NULL to take the only connected device.
 * Returns NULL on failure, with out_error set.
 */
MirageDevice *mirage_idevice_open(const char *udid, char **out_error);

/*
 * Connect over TCP with a pairing file, and open the location-simulation service.
 *
 * On the iPhone this is how Mirage reaches itself. `address` is the peer address handed
 * out by a loopback VPN — LocalDevVPN uses 10.7.0.1. The VPN is needed because lockdownd
 * refuses connections from 127.0.0.1; routed through a tun interface the packets arrive
 * with a non-loopback source and the app is treated like any other paired host.
 *
 * ddi_dir may be NULL. When given it is a folder holding a developer disk image —
 * Image.dmg, a .trustcache and BuildManifest.plist — which Mirage mounts if the device
 * has none. A mount does not survive a reboot, so without this the phone needs a Mac
 * again after every restart.
 *
 * Returns NULL on failure, with out_error set.
 */
MirageDevice *mirage_idevice_open_loopback(const char *address,
                                           const char *pairing_file_path,
                                           const char *ddi_dir, char **out_error);

/* Set the simulated location. Returns MIRAGE_OK or MIRAGE_ERR. */
int mirage_idevice_set(MirageDevice *handle, double latitude, double longitude,
                       char **out_error);

/*
 * Clear any simulated location. Safe to call when nothing is simulated — that is a no-op
 * on the device, which is what lets restore() run unconditionally.
 */
int mirage_idevice_clear(MirageDevice *handle, char **out_error);

/*
 * Close and release. Deliberately does NOT clear the location: a simulated position
 * outliving the process is documented behaviour, and undoing it silently on teardown would
 * hide the one state the user most needs to know about.
 */
void mirage_idevice_close(MirageDevice *handle);

/* Release a message produced by any call above. */
void mirage_idevice_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* MIRAGE_IDEVICE_H */
