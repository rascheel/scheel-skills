# OCI Mount → Snap Construct Mapping

This reference maps OCI runtime mount entries (from `config.json` → `mounts`)
to their snap equivalent. Consult this file during Step 3 of the analysis checklist.

---

## How to Use

For each object in `mounts`, identify `type`, `source`, and `destination`.
Find the matching row below. Record whether:
- The mount is **auto-provided** by snapd (no action needed)
- A **snap interface** is required
- A **layout** entry is required

---

## Standard / Pseudo-filesystem Mounts

These are virtual filesystems that snapd provides automatically inside every
strictly-confined snap's mount namespace. **No interface or layout needed.**

| `destination` | `type` | Snap treatment |
|---|---|---|
| `/proc` | `proc` | Auto-provided by snapd |
| `/dev` | `tmpfs` | Auto-provided by snapd |
| `/dev/pts` | `devpts` | Auto-provided by snapd |
| `/dev/shm` | `tmpfs` | Auto-provided by snapd (within snap's own shm) |
| `/dev/mqueue` | `mqueue` | Auto-provided by snapd |
| `/sys` | `sysfs` / `bind` | Auto-provided (read-only) by snapd |
| `/sys/fs/cgroup` | `cgroup` / `cgroup2` | Auto-provided (read-only) by snapd |

---

## Network / Resolver Mounts

| `destination` | `source` | Snap treatment |
|---|---|---|
| `/etc/resolv.conf` | `/etc/resolv.conf` (bind) | Provided automatically when the `network` interface is connected. Add `plugs: [network]`. No layout needed |
| `/etc/hosts` | `/etc/hosts` (bind) | Same as above — `network` interface |
| `/etc/hostname` | `/etc/hostname` (bind) | Covered by `network-observe` or `network` interface |

---

## Application Data — Bind Mounts from Host

When `source` is an absolute host path and `options` includes `rbind`:

| Source category | Writable? | Snap approach |
|---|---|---|
| Host config files (e.g. `/etc/myapp/`) | No | **Layout**: `/<dest>: bind: $SNAP/etc/myapp` if file ships in snap; or `$SNAP_COMMON/etc/myapp` if operator-managed |
| Host data / state directory | Yes | **Layout**: `/<dest>: bind: $SNAP_COMMON/<subdir>` |
| Host secrets / credentials | No | **Layout**: `/<dest>: bind: $SNAP_COMMON/<subdir>` (operator populates post-install) |
| Host device path (`/dev/…`) | Yes | Interface-dependent — see device table below |

---

## Device Bind Mounts

| `source` / `destination` | Snap interface |
|---|---|
| `/dev/ttyUSB*`, `/dev/ttyACM*`, `/dev/ttyS*` | `serial-port` |
| `/dev/i2c-*` | `i2c` |
| `/dev/spidev*` | `spi` |
| `/dev/gpio*`, `/sys/class/gpio/` | `gpio` |
| `/dev/video*` | `camera` |
| `/dev/dri/`, `/dev/mali*` | `opengl` or `graphics-core22` |
| `/dev/input/` | `joystick` or `raw-input` |
| `/dev/net/tun` | `network-control` |
| `/dev/urandom`, `/dev/random` | Auto-provided — no interface needed |
| `/dev/sysgenid` | `hardware-observe` (or drop if not critical) |
| `/dev/bus/usb/` | `raw-usb` |
| Bluetooth (`/dev/rfcomm*`, `/dev/hci*`) | `bluetooth-control` |

---

## Shared Memory Mounts (cross-process)

| Scenario | Snap approach |
|---|---|
| SHM shared **within** the same snap | Auto-provided, no interface needed |
| SHM shared **between two snaps** | `shared-memory` interface with matching `private` label on both sides |
| Named POSIX semaphores between snaps | Same as above |

---

## Tmpfs Mounts (ephemeral)

Tmpfs mounts used for scratch space are handled automatically inside the snap
mount namespace. If the application path is hardcoded to a specific tmpfs
location (e.g. `/run/myapp`), add a layout:

```yaml
layout:
  /run/myapp:
    bind: $XDG_RUNTIME_DIR/myapp   # ephemeral, per-user
  # OR for system daemons:
  /run/myapp:
    bind: $SNAP_DATA/run/myapp     # persists across reboots if needed
```

---

## Masked / Read-Only Paths

OCI `maskedPaths` and `readonlyPaths` in `config.json → linux` are security
hardening measures applied inside the container. In a snap these are handled
automatically by snapd's AppArmor and mount namespace policy. **No action
required** — do not try to replicate them with layouts.

---

## Decision algorithm

```
For each mount entry in config.json:
  1. If destination is in the "Standard / Pseudo-filesystem" table → skip (auto).
  2. If destination is /etc/resolv.conf or /etc/hosts → add `network` plug.
  3. If source is a host device path (/dev/…) → find interface in device table.
  4. If source is a host data directory:
       a. Writable at runtime? → layout to $SNAP_COMMON/<subdir>
       b. Read-only, ships inside snap? → layout to $SNAP/<subdir>
       c. Read-only, operator-provisioned? → layout to $SNAP_COMMON/<subdir>
  5. If type is tmpfs for scratch → layout to $XDG_RUNTIME_DIR or $SNAP_DATA/run
```
