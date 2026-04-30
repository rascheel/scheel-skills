# Snap Interfaces Catalog

Each entry lists: the interface name, what it grants, detection signals, and whether it is auto-connected on install (AC) or requires a manual `snap connect` (MC).

---

## Network

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `network` | Outbound TCP/UDP | HTTP clients, WebSocket, gRPC, DNS lookups, any `connect()` syscall | AC |
| `network-bind` | Listen on ports | `bind()` + `listen()`, `--port`, `--listen`, server/daemon apps | AC |
| `network-control` | Manage network interfaces, iptables | `ip link`, `iptables`, `tc`, netlink `RTM_*` | MC |
| `network-manager` | NetworkManager D-Bus API | `org.freedesktop.NetworkManager`, `nmcli` | MC |
| `network-observe` | Read-only network config | `ip addr`, `netstat`, `ss` without modification | AC |
| `firewall-control` | nftables / iptables writes | nftables, `iptables -A`, firewall management | MC |

---

## Filesystem

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `home` | Read/write `$HOME` (excluding hidden dirs by default) | File open in `~/`, `os.path.expanduser`, `$HOME` references | AC (on Ubuntu desktop; MC on server/IoT) |
| `removable-media` | `/media`, `/mnt`, `/run/media` | Removable drive access, `udisks`, mount commands | MC |
| `mount-observe` | Read `/proc/mounts`, `mountinfo` | `df`, `/proc/mounts` reads | AC |
| `system-files` | Specific system paths declared via `slots` | Hardcoded paths in `/etc`, `/var`, `/usr` not covered by layouts | MC |
| `personal-files` | Specific `$HOME` subdirs declared via `slots` | Dotfiles, `~/.config/<appname>` | MC |

---

## Hardware / Devices

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `serial-port` | `/dev/ttyS*`, `/dev/ttyUSB*`, `/dev/ttyACM*` | Serial port open, `termios`, UART communication | MC |
| `raw-usb` | Raw USB via libusb (`/dev/bus/usb`) | `libusb`, `usb_open()`, HID devices | MC |
| `bluetooth-control` | BlueZ D-Bus, HCI socket | `bluetoothctl`, `libbluetooth`, `org.bluez` | MC |
| `camera` | `/dev/video*` (V4L2 webcams) | `v4l2`, `cv2.VideoCapture`, webcam/camera access | MC |
| `gpio` | GPIO sysfs and character device | `/sys/class/gpio`, `/dev/gpiochip*`, Raspberry Pi GPIO | MC |
| `i2c` | I2C bus devices | `/dev/i2c-*`, `smbus`, I2C sensor libraries | MC |
| `spi` | SPI bus devices | `/dev/spidev*`, `spidev` Python module | MC |
| `opengl` | GPU access (OpenGL, Vulkan, CUDA, VA-API) | `glx`, `egl`, `vulkan`, CUDA, hardware video decode | AC (on most systems) |

---

## Audio / Video

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `audio-playback` | PulseAudio / PipeWire playback | `pa_simple_new`, `pygame.mixer`, any audio output | AC |
| `audio-record` | Microphone / audio input | `pa_simple_new(PA_STREAM_RECORD)`, microphone access | MC |

---

## Desktop / GUI

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `desktop` | Session D-Bus, XDG portals, basic desktop integration | GUI apps, `.desktop` file, `xdg-open`, session D-Bus | AC |
| `desktop-legacy` | AT-SPI, legacy desktop access patterns | Older GTK/Qt accessibility needs | AC |
| `wayland` | Wayland compositor socket | `WAYLAND_DISPLAY`, `wl_*` APIs, native Wayland apps | AC |
| `x11` | X11 display socket | `DISPLAY`, Xlib, Xcb, non-Wayland GUI apps | AC |
| `unity7` | Unity/GNOME legacy integration | Older Ubuntu desktop apps | AC |
| `gsettings` | Read/write GSettings (GNOME config) | `Gio.Settings`, `gsettings` CLI, GNOME app config | AC |
| `cups-control` | Print via CUPS | Printing functionality | MC |

---

## System Observation / Control

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `system-observe` | Read `/proc`, `/sys`, process list | `ps`, `top`, system monitoring tools | AC |
| `hardware-observe` | Read hardware info (`/sys/class/dmi`, `lshw`) | `dmidecode`, hardware inventory, sensor reads | AC |
| `process-control` | `kill()`, `setpriority()`, `ptrace` of own processes | Process management tools, `nice`, `renice` | MC |
| `ptrace` | `ptrace()` syscall (debuggers, profilers) | `gdb`, `strace`, `perf`, profiling tools | MC |
| `log-observe` | Read `/var/log`, `journalctl` | Log readers, monitoring agents, `/var/log` access | AC |
| `time-control` | Set system clock, RTC | `hwclock`, `date -s`, NTP clients that set time | MC |
| `hostname-control` | Read/write hostname | `hostnamectl set-hostname` | MC |
| `locale-control` | Read/write locale | `localectl` | MC |
| `timezone-control` | Read/write timezone | `timedatectl set-timezone` | MC |

---

## D-Bus

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `dbus` (plug) | Connect to a named D-Bus service | App uses a specific named service on session or system bus | MC or AC depending on policy |
| `dbus` (slot) | Expose a D-Bus service | App registers a well-known name on D-Bus | — |
| `login-session-observe` | `org.freedesktop.login1` read | Session management, seat detection | AC |
| `udisks2` | `org.freedesktop.UDisks2` | Disk management, automount, `udisksctl` | MC |
| `upower-observe` | `org.freedesktop.UPower` | Battery status, power management | AC |
| `accounts-service` | `org.freedesktop.Accounts` | User account queries | MC |

---

## Location

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `location-observe` | Read location from location service | GPS usage, geolocation APIs, map applications | MC |
| `location-control` | Manage location sources | Location service configuration | MC |

---

## Security / Credentials

| Interface | Grants | Detection signals | Connect |
|-----------|--------|-------------------|---------|
| `password-manager-service` | Secret Service D-Bus API (`org.freedesktop.secrets`) | Keychain access, GNOME Keyring, KWallet | MC |
| `ssh-keys` | Read `~/.ssh` | SSH client tools, git over SSH | MC |
| `gpg-keys` | Read `~/.gnupg` | GPG operations, encrypted email | MC |

---

## Auto-connect Summary

**Auto-connected on install (no user action needed):**
`network`, `network-bind`, `network-observe`, `home` (desktop), `opengl`, `audio-playback`, `desktop`, `desktop-legacy`, `wayland`, `x11`, `unity7`, `gsettings`, `mount-observe`, `system-observe`, `hardware-observe`, `log-observe`, `upower-observe`, `login-session-observe`

**Require manual `snap connect` (user must explicitly grant):**
`network-control`, `network-manager`, `firewall-control`, `removable-media`, `system-files`, `personal-files`, `serial-port`, `raw-usb`, `bluetooth-control`, `camera`, `gpio`, `i2c`, `spi`, `audio-record`, `process-control`, `ptrace`, `time-control`, `hostname-control`, `locale-control`, `timezone-control`, `udisks2`, `location-observe`, `location-control`, `password-manager-service`, `ssh-keys`, `gpg-keys`, `cups-control`

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
```
