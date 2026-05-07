# Snap Interfaces Catalog

Each entry lists: the interface name, what it grants, detection signals, and whether it is auto-connected on install (AC) or requires a manual `snap connect` (MC).

> **Legend:** AC = auto-connects on install · MC = manual connect required · AC\* = conditional auto-connect (see notes)

---

## Network

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `network` | Outbound TCP/UDP | HTTP clients, WebSocket, gRPC, DNS lookups, any `connect()` syscall | AC |
| `network-bind` | Listen on ports | `bind()` + `listen()`, `--port`, `--listen`, server/daemon apps | AC |
| `network-control` | Manage network interfaces, iptables, routes | `ip link`, `iptables`, `tc`, netlink `RTM_*`, VPN daemons | MC |
| `network-manager` | Full NetworkManager D-Bus API (read + write) | `org.freedesktop.NetworkManager`, `nmcli`, WiFi management | MC |
| `network-manager-observe` | Read-only NetworkManager settings via D-Bus | `nmcli` read-only, observing NM state changes | MC |
| `network-observe` | Read-only network config (`ip`, `ss`, `netstat`) | `ip addr`, `netstat`, `ss` without modification, network diagnostics | MC |
| `network-status` | Access NetworkingStatus service | Checking online/offline state, network connectivity monitors | AC |
| `network-setup-observe` | Read netplan configuration files | Netplan readers, network config display tools | MC |
| `network-setup-control` | Modify netplan configuration | Netplan writers, network provisioning tools | MC |
| `firewall-control` | nftables / iptables writes | nftables, `iptables -A`, firewall management | MC |

---

## Filesystem

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `home` | Read/write `$HOME` (excluding hidden dirs by default) | File open in `~/`, `os.path.expanduser`, `$HOME` references | AC (on Ubuntu desktop; MC on server/IoT) |
| `removable-media` | `/media`, `/mnt`, `/run/media` | Removable drive access, `udisks`, mount commands | MC |
| `mount-observe` | Read-only access to mount table and quota info | `df`, `/proc/mounts`, `mountinfo` reads | MC |
| `system-files` | Specific host system paths declared via `slots` | Hardcoded paths in `/etc`, `/var`, `/usr` not covered by layouts | MC |
| `personal-files` | Specific `$HOME` subdirs declared via `slots` | Dotfiles, `~/.config/<appname>` outside `$SNAP_USER_DATA` | MC |
| `content` | Share directories/files/sockets between snaps | Shared themes, libraries, plugins across snaps; `default-provider` attribute | AC\* (same publisher; MC otherwise) |
| `fuse-support` | Mount FUSE filesystems | `libfuse`, FUSE-based VFS (e.g. sshfs, encfs); mount point must be in `$SNAP_DATA` or `$SNAP_COMMON` | MC |
| `mount-control` | Mount/unmount transient or persistent filesystems | `mount` syscall outside snap dirs; NFS, CIFS, ext4, FUSE mounts | MC |
| `system-backup` | Read-only access to system paths for backups | Backup agents, archival tools reading `/etc`, `/home` | MC |

> **`content` interface notes:** Producer snap declares a `slot` with `read`/`write` paths; consumer snap declares a `plug` with a `target` path and matching `content` identifier. Use `default-provider: <snap-name>` on the plug to trigger automatic slot snap installation. Snaps from the same publisher auto-connect.

---

## Hardware / Devices

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `serial-port` | `/dev/ttyS*`, `/dev/ttyUSB*`, `/dev/ttyACM*` | Serial port open, `termios`, UART communication | MC |
| `raw-usb` | Raw USB via libusb (`/dev/bus/usb`) | `libusb`, `usb_open()`, custom USB protocols | MC |
| `hidraw` | Raw HID devices (`/dev/hidraw*`) via USB or Bluetooth | HID protocol access, game controllers, drawing tablets, custom USB HID | MC |
| `uinput` | Write to `/dev/uinput` (inject input events) | Virtual input device creation, input remapping tools | MC |
| `joystick` | Joystick/gamepad devices (`/dev/input/js*`, `/dev/input/event*`) | SDL joystick, gamepad input, game controllers | MC |
| `camera` | `/dev/video*` (V4L2 webcams and capture cards) | `v4l2`, `cv2.VideoCapture`, webcam/camera access | MC |
| `bluetooth-control` | Raw BlueZ HCI socket access | Low-level `bluetoothctl`, `libbluetooth`, custom BT stacks | MC |
| `gpio` | GPIO sysfs (`/sys/class/gpio`) and legacy chardev | `/sys/class/gpio`, Raspberry Pi GPIO; prefer `gpio-chardev` on UC24+ | MC |
| `gpio-chardev` | Modern GPIO chardev lines via `/dev/snap/gpio-chardev/` | New `libgpiod` v2 API, RPi5+ GPIO; requires gadget snap slot; UC24+ | MC |
| `i2c` | I2C bus devices (`/dev/i2c-*`) | `smbus`, I2C sensor libraries, `python-smbus` | MC |
| `spi` | SPI bus devices (`/dev/spidev*`) | `spidev` Python module, SPI flash/sensor access | MC |
| `iio` | Specific IIO sensor device (`/dev/iio:device*`) | Industrial I/O sensors (accelerometers, gyros, ADCs) | MC |
| `can-bus` | Controller Area Network bus | Automotive CAN protocols, `python-can`, `socketcan` | MC |
| `dvb` | All DVB devices and APIs | Digital TV tuners, `libdvbv5`, TV capture | MC |
| `optical-drive` | Read (and optionally write) to CD/DVD/Blu-Ray drives | CD/DVD playback, `cdparanoia`, disc burning (`write: true`) | AC (read-only); MC when `write: true` |
| `opengl` | GPU access (OpenGL, Vulkan, CUDA, VA-API) | `glx`, `egl`, `vulkan`, CUDA, hardware video decode/encode | AC |
| `kvm` | `/dev/kvm` KVM hypervisor access | QEMU/KVM VMs, `libvirt`, emulators | MC |
| `libvirt` | libvirt control socket (`libvirtd`) | `libvirtd`, `virsh`, QEMU/KVM management via libvirt API | MC |
| `hardware-random-observe` | Read `/dev/hwrng` (hardware RNG) | Hardware entropy sources, HSM, crypto accelerators | MC |
| `tpm` | `/dev/tpm0` and `/dev/tpmrm0` (Trusted Platform Module) | TPM-backed key storage, measured boot, LUKS + TPM | MC |

---

## Audio / Video

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `audio-playback` | PulseAudio / PipeWire audio output | `pa_simple_new`, `pygame.mixer`, SDL audio, any sound output | AC |
| `audio-record` | Microphone / audio input via PulseAudio / PipeWire | `pa_simple_new(PA_STREAM_RECORD)`, microphone, voice input | MC |
| `alsa` | Raw ALSA audio devices (playback + record) | Direct `libasound2` / ALSA usage; bypasses PulseAudio/PipeWire mixing | MC |
| `pipewire` | Full PipeWire socket access | Low-level PipeWire API, snapped desktop environments, pro-audio | MC |
| `mpris` | MPRIS D-Bus media player control | `org.mpris.MediaPlayer2`, media keys (play/pause), `playerctl` | MC |
| `pulseaudio` | **(Deprecated since snapd 2.41)** PulseAudio socket | Legacy; use `audio-playback` / `audio-record` instead | MC |

> **Audio interface guidance:** Use `audio-playback` and `audio-record` for virtually all apps — they cover PulseAudio and PipeWire. Add `alsa` only if your app needs raw ALSA for latency-critical audio and ships `libasound2` in stage-packages.

---

## Desktop / GUI

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `desktop` | Session D-Bus, XDG portals, basic desktop integration | GUI apps, `.desktop` file, `xdg-open`, session D-Bus | AC |
| `desktop-legacy` | AT-SPI accessibility, input methods (IBus/Fcitx) | Older GTK/Qt apps, accessibility services | AC |
| `wayland` | Wayland compositor socket | `WAYLAND_DISPLAY`, `wl_*` APIs, native Wayland apps | AC |
| `x11` | X11 display socket | `DISPLAY`, Xlib, Xcb, non-Wayland GUI apps | AC |
| `unity7` | Unity/GNOME legacy integration (AppIndicators, HUD) | Older Ubuntu desktop apps, system tray icons | AC |
| `gsettings` | Read/write GSettings (GNOME config) | `Gio.Settings`, `gsettings` CLI, GNOME app config | AC |
| `browser-support` | Chromium/Firefox sandbox APIs, `clone()`, `chroot()` | Electron apps, embedded Chromium, web browsers | AC (without sandbox); MC when `allow-sandbox: true` |
| `screen-inhibit-control` | Inhibit screen lock/sleep/screensaver | Video players, presentation apps, `xdg-screensaver`, `caffeine` | AC |
| `display-control` | Set display brightness and other parameters | Brightness controls, kiosk apps, power management UIs | MC |

> **`browser-support` notes:** Electron apps should use `allow-sandbox: false` (the default) — the snap's confinement acts as the sandbox. Setting `allow-sandbox: true` requires trusted publisher status and manual connect.

---

## Printing

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `cups` | Submit print jobs via CUPS snap (no admin access) | Any printing functionality in new snaps; requires `cups` snap | AC\* (auto-connects to cups snap slot; requires `assumes: [snapd2.55]`) |
| `cups-control` | Full CUPS socket (job submission + admin) | Printer setup tools, legacy printing; allows queue creation/modification | MC |

> **Printing guidance:** New apps should use `cups` (safer, no admin). Switch to `cups` if you currently use `cups-control` for simple printing. Keep `cups-control` only for printer administration tools. Add `assumes: [snapd2.55]` when using `cups`.

---

## System Observation / Control

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `system-observe` | Read-only `/proc`, `/sys`, full process list | `ps aux`, `top`, `htop`, system monitoring agents | MC |
| `hardware-observe` | Read hardware info from `/sys`, `/proc`; `lspci`, `lsusb`, `lshw`, `sensors` | `dmidecode`, hardware inventory, sensor reads, `hwinfo` | MC |
| `log-observe` | Read `/var/log`, `journalctl`, set kernel log rate-limiting | Log readers, monitoring agents, syslog access | MC |
| `mount-observe` | Read-only mount table and quota info | `df`, `/proc/mounts` reads, filesystem monitoring | MC |
| `process-control` | `kill()`, `setpriority()` on any process | Process management tools, `nice`, `renice`, task managers | MC |
| `ptrace` | `ptrace()` syscall (attach to any process) | `gdb`, `strace`, `ltrace`, profilers | MC |
| `system-trace` | Kernel tracing facilities (perf, eBPF, ftrace) | `perf`, `bpftrace`, `ftrace`, `SystemTap` | MC |
| `daemon-notify` | Send systemd `sd_notify` status from service | Services using `sd_notify()`, `Type=notify` systemd units | MC |
| `shutdown` | Shut down or restart the system | `systemctl poweroff`, `reboot`, power management daemons | MC |
| `time-control` | Set system clock and RTC | `hwclock`, `date -s`, NTP clients that set time | MC |
| `timeserver-control` | Change NTP server configuration | `timedatectl set-ntp`, NTP configuration tools | MC |
| `hostname-control` | Read/write system hostname | `hostnamectl set-hostname` | MC |
| `locale-control` | Read/write system locale | `localectl` | MC |
| `timezone-control` | Read/write timezone | `timedatectl set-timezone` | MC |

> **Correction note:** `system-observe`, `hardware-observe`, `log-observe`, `mount-observe` are all **manual connect** — the Snapcraft docs list them as "no". They do not auto-connect.

---

## D-Bus / Services

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `dbus` (plug) | Connect to a named D-Bus service on session or system bus | App uses a specific well-known D-Bus name | MC (or AC if store-approved) |
| `dbus` (slot) | Expose a snap's own D-Bus service | App registers a well-known D-Bus name | — |
| `avahi-observe` | Discover mDNS/DNS-SD services on local network | `avahi_service_browser_new`, Bonjour/mDNS discovery, `_tcp` service lookup | MC |
| `avahi-control` | Advertise services and control avahi-daemon | Registering mDNS services, `avahi_entry_group_add_service` | MC |
| `bluez` | BlueZ Bluetooth service D-Bus API (client) | `dbus-bluez`, high-level BT APIs, `bleak`, `bluez` library | MC |
| `modem-manager` | ModemManager D-Bus API (read + write) | Cellular modem access, SMS, data connections via `mmcli` | MC |
| `login-session-observe` | Read-only `org.freedesktop.login1` (logind) | Session management, seat detection, user session listing | MC |
| `login-session-control` | Full logind access, setup login sessions | Session managers, display managers, PAM integrations | MC |
| `udisks2` | `org.freedesktop.UDisks2` D-Bus API | Disk management, automount, `udisksctl`, partition tools | MC |
| `upower-observe` | `org.freedesktop.UPower` read (battery/power status) | Battery indicators, power management, `upower` CLI | AC |
| `accounts-service` | `org.freedesktop.Accounts` D-Bus API | User account queries, avatar fetching | MC |
| `online-accounts-service` | Ubuntu Online Accounts service | Apps using Ubuntu SSO / online account tokens | AC |

> **`bluez` vs `bluetooth-control`:** Use `bluez` for high-level Bluetooth via the BlueZ D-Bus API (typical for apps). Use `bluetooth-control` only for raw HCI socket access (custom BT stacks, firmware tools).

---

## IPC (Inter-Process Communication)

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `shared-memory` | Shared `/dev/shm` paths between snaps | Shared memory IPC (`shm_open`), cross-snap data sharing; `private: true` for snap-private `/dev/shm` | AC\* (same publisher or `private: true`; MC otherwise) |
| `posix-mq` | POSIX message queues (`/dev/mqueue`) between snaps | `mq_open`, `mq_send`, `mq_receive` across snap boundaries | AC\* (same publisher; MC otherwise) |

> **IPC interface notes:** Both `shared-memory` and `posix-mq` require a slot (provider) and plug (consumer). Slot is super-privileged (gadget/OS/store-approved). For private per-snap shared memory, use `plugs: { shared-memory: { private: true } }` — this auto-connects without a slot snap.

---

## Location

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `location-observe` | Read location from the location service | GPS usage, geolocation APIs, map applications | MC |
| `location-control` | Manage location sources and providers | Location service configuration | MC |

---

## Security / Credentials

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `password-manager-service` | Secret Service D-Bus API (`org.freedesktop.secrets`) | Keychain access, GNOME Keyring, KWallet, `secretstorage` | MC |
| `ssh-keys` | Read `~/.ssh` (private + public keys) | SSH client tools that need private keys, git over SSH, `paramiko` | MC |
| `ssh-public-keys` | Read-only `~/.ssh` public keys and non-sensitive config | Tools that only need public keys or `known_hosts` | MC |
| `gpg-keys` | Read `~/.gnupg` (private + public keys) | GPG signing/decryption, encrypted email, `python-gnupg` | MC |
| `gpg-public-keys` | Read-only GPG public keys and non-sensitive config | Tools that only verify signatures or encrypt | MC |
| `pcscd` | PC/SC smart card daemon (PCSD) socket | Smart card readers, PIV tokens, PKCS#11 via PC/SC | MC |
| `u2f-devices` | Read/write U2F/FIDO2 security keys (hidraw) | `python-fido2`, WebAuthn clients, `yubikey-manager` | MC |
| `tpm` | Trusted Platform Module (`/dev/tpm0`, `/dev/tpmrm0`) | TPM-backed attestation, key sealing, `tpm2-tools` | MC |

---

## Personal Data

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `calendar-services` | Evolution Data Server (EDS) calendar D-Bus API | GNOME Calendar integration, `libecal`, EDS calendar access | MC |
| `contacts-service` | Evolution Data Server (EDS) address book D-Bus API | GNOME Contacts integration, `libebook`, EDS address book | MC |

---

## Auto-connect Summary

**Auto-connected on install (no user action needed):**

| Interface | Notes |
|-----------|-------|
| `network` | All snaps |
| `network-bind` | All snaps |
| `network-status` | Network connectivity monitor |
| `home` | Desktop only; MC on server/IoT |
| `opengl` | GPU access |
| `audio-playback` | Sound output |
| `desktop` | GUI apps |
| `desktop-legacy` | Legacy desktop |
| `wayland` | Wayland GUI |
| `x11` | X11 GUI |
| `unity7` | Ubuntu desktop |
| `gsettings` | GNOME config |
| `upower-observe` | Battery/power info |
| `screen-inhibit-control` | Prevent sleep/lock |
| `optical-drive` | CD/DVD read-only (MC when `write: true`) |
| `browser-support` | Without `allow-sandbox: true` |
| `online-accounts-service` | Ubuntu online accounts |
| `content` | Same-publisher snaps only |
| `shared-memory` | Same-publisher or `private: true` |
| `posix-mq` | Same-publisher snaps only |
| `cups` | Via cups snap slot (not snapd itself) |

**Require manual `snap connect` (user or store must explicitly grant):**

`network-control`, `network-manager`, `network-manager-observe`, `network-observe`, `network-setup-observe`, `network-setup-control`, `firewall-control`, `removable-media`, `mount-observe`, `system-files`, `personal-files`, `fuse-support`, `mount-control`, `system-backup`, `serial-port`, `raw-usb`, `hidraw`, `uinput`, `joystick`, `camera`, `bluetooth-control`, `gpio`, `gpio-chardev`, `i2c`, `spi`, `iio`, `can-bus`, `dvb`, `optical-drive` (write), `kvm`, `libvirt`, `hardware-random-observe`, `tpm`, `alsa`, `pipewire`, `mpris`, `pulseaudio`, `browser-support` (with sandbox), `display-control`, `cups-control`, `system-observe`, `hardware-observe`, `log-observe`, `process-control`, `ptrace`, `system-trace`, `daemon-notify`, `shutdown`, `time-control`, `timeserver-control`, `hostname-control`, `locale-control`, `timezone-control`, `dbus`, `avahi-observe`, `avahi-control`, `bluez`, `modem-manager`, `login-session-observe`, `login-session-control`, `udisks2`, `accounts-service`, `shared-memory` (cross-publisher), `posix-mq` (cross-publisher), `location-observe`, `location-control`, `password-manager-service`, `ssh-keys`, `ssh-public-keys`, `gpg-keys`, `gpg-public-keys`, `pcscd`, `u2f-devices`, `calendar-services`, `contacts-service`

---

## Interface Declaration Examples

```yaml
# Top-level plugs (apply to all apps unless overridden per-app)
plugs:
  serial-port:
    interface: serial-port
    path: /dev/ttyUSB0    # pin to a specific device (optional)

# Per-app plugs
apps:
  my-app:
    command: bin/my-app
    plugs:
      - network
      - home
      - audio-playback
      - camera

# Exposing a D-Bus service
slots:
  my-service:
    interface: dbus
    bus: session
    name: com.example.MyService

# content interface — producer snap
slots:
  my-themes:
    interface: content
    content: gtk-3-themes
    read:
      - $SNAP/share/themes

# content interface — consumer snap
plugs:
  gtk-3-themes:
    interface: content
    content: gtk-3-themes
    default-provider: gtk-common-themes
    target: $SNAP/data-dir/themes

# shared-memory — private per-snap /dev/shm
plugs:
  shared-memory:
    private: true

# daemon-notify — for systemd notify services
apps:
  my-daemon:
    command: bin/my-daemon
    daemon: simple
    plugs:
      - network
      - daemon-notify
```
