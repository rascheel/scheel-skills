# AppArmor Denial → Snap Interface Reference

Use this table when `snappy-debug` does not provide an explicit `suggested plug:` line.
Match the denial message against the **Denial keyword / path pattern** column and add the
corresponding interface to the app that triggered it.

---

## Network

| Denial keyword / path pattern | Snap interface |
|---|---|
| `network` (TCP/UDP connect/bind) | `network` |
| `network-bind` (listening on a port) | `network-bind` |
| `network-control` (routing, iptables) | `network-control` |
| `network-observe` (read-only netlink) | `network-observe` |
| `netlink` socket access | `network` or `network-control` |
| `/etc/resolv.conf` read | `network` |

---

## Files & Storage

| Denial keyword / path pattern | Snap interface |
|---|---|
| `/home/**` read/write | `home` |
| `/media/**`, `/mnt/**`, `/run/media/**` | `removable-media` |
| `/etc/**` write | `etc-passwd` (specific files) or `system-files` |
| `/var/log/**` write | `log-observe` |
| `/proc/**` read | `system-observe` |
| `/sys/**` read | `hardware-observe` |
| `/dev/sda*`, `/dev/nvme*` | `block-devices` |
| `/run/udev/**` | `hardware-observe` |

---

## System & Process

| Denial keyword / path pattern | Snap interface |
|---|---|
| `ptrace` | `process-control` |
| `signal` (sending to other processes) | `process-control` |
| `mount` / `umount` | `mount-observe` (read) or `system-mount` |
| `pivot_root` | `system-mount` |
| `chroot` | `system-mount` |
| `/proc/sys/kernel/**` write | `kernel-module-control` |
| `sys_admin` capability | `system-mount` or `kernel-module-control` |
| `sys_ptrace` capability | `process-control` |
| `sys_nice` capability | `process-control` |

---

## Hardware & Devices

| Denial keyword / path pattern | Snap interface |
|---|---|
| `/dev/tty*`, `/dev/pts/*` | `opengl` (if GPU) or `raw-input` |
| `/dev/input/**` | `raw-input` |
| `/dev/video*` | `camera` |
| `/dev/snd/**`, `/dev/dsp*` | `audio-playback` / `audio-record` |
| `/dev/bus/usb/**` | `raw-usb` |
| `/dev/i2c-*` | `i2c` |
| `/dev/spi*` | `spi` |
| `/dev/gpio*` | `gpio` |
| `/dev/dri/**`, `/dev/mali*` | `opengl` |
| `/sys/class/power_supply/**` | `hardware-observe` |
| Bluetooth socket | `bluetooth-control` |

---

## D-Bus

| Denial keyword / path pattern | Snap interface |
|---|---|
| D-Bus session bus access | `unity7` (legacy) or a custom `content` interface |
| D-Bus system bus access | `system-dbus` or specific well-known interface |
| `org.freedesktop.NetworkManager` | `network-manager` |
| `org.freedesktop.UPower` | `upower-observe` |
| `org.freedesktop.login1` | `login-session-observe` |
| `org.freedesktop.PolicyKit1` | `polkit` |

---

## IPC & Sockets

| Denial keyword / path pattern | Snap interface |
|---|---|
| `/run/snapd-snap.socket` | built-in (no extra plug needed) |
| `/run/user/*/pulse` (PulseAudio) | `audio-playback` / `audio-record` |
| `/run/user/*/pipewire-*` | `audio-playback` / `audio-record` |
| `/tmp/.X*` (X11) | `x11` |
| Wayland socket | `wayland` |
| `/run/dbus/system_bus_socket` | `system-dbus` |

---

## SecComp Denials

SecComp denials indicate a blocked syscall. Common cases:

| Denied syscall | Snap interface |
|---|---|
| `clone` with `CLONE_NEWUSER` | `system-mount` |
| `unshare` | `system-mount` |
| `keyctl` | `kernel-keyring` |
| `perf_event_open` | `perf-event` |
| `bpf` | `bpf` |
| `io_uring_*` | no standard interface; may need a layout |

---

## Tips

- When in doubt, run `snap interface <interface-name>` inside the container to see exactly
  what paths and capabilities the interface grants before adding it.
- Some interfaces are auto-connected on install (e.g., `network`, `home` on Ubuntu Desktop);
  others require manual connection or store review (`raw-usb`, `block-devices`, etc.).
- If no interface maps to the denial, the snap may need a `layout:` stanza or a custom
  AppArmor snippet — escalate to the snap author.
