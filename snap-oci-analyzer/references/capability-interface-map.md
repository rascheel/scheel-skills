# Linux Capability → Snap Interface Mapping

This reference maps Linux POSIX capabilities (as they appear in OCI `config.json`
under `process.capabilities`) to their nearest snap interface or confinement
construct. Consult this file when Step 2 of the analysis checklist asks you to
map each capability.

---

## How to Use

For each capability listed in `bounding`, `effective`, `permitted`, `inheritable`,
and `ambient`, find the row below and record:
- The **snap interface** to add as a plug (if any)
- Whether the capability is **granted by default** inside strict confinement
- Whether it requires a **store review / custom confinement** exception

---

## Table of Contents
1. [Network capabilities](#network-capabilities)
2. [Process / signal capabilities](#process--signal-capabilities)
3. [Filesystem capabilities](#filesystem-capabilities)
4. [System / kernel capabilities](#system--kernel-capabilities)
5. [Audit capabilities](#audit-capabilities)
6. [IPC & device capabilities](#ipc--device-capabilities)
7. [Capabilities that cannot be granted via interfaces](#capabilities-that-cannot-be-granted-via-interfaces)

---

## Network capabilities

| Capability | Snap interface / construct | Notes |
|---|---|---|
| `CAP_NET_BIND_SERVICE` | `network-bind` | Allows binding to ports < 1024 |
| `CAP_NET_RAW` | `network-control` | Raw sockets; requires store review |
| `CAP_NET_ADMIN` | `network-control` | Full network admin; requires store review |
| `CAP_NET_BROADCAST` | `network-control` | Rarely needed; requires store review |

---

## Process / signal capabilities

| Capability | Snap interface / construct | Notes |
|---|---|---|
| `CAP_KILL` | *(none — default within snap)* | Snaps may signal their own processes by default. Only add `process-control` if the app needs to signal processes **outside** its own snap |
| `CAP_SETUID` | *(none — default within snap; `system-usernames` required for drops to a declared system user)* | Root-inside-snap can `setresuid` to a user declared in `system-usernames:` (e.g. `_daemon_`). The AppArmor profile grants `setresuid`/`setresgid` only for those declared users. Dropping to an arbitrary external UID without `system-usernames` will fail |
| `CAP_SETGID` | *(none — default within snap; see `CAP_SETUID`)* | Same rules as `CAP_SETUID` |
| `CAP_SETPCAP` | *(drop — usually not needed)* | Capability manipulation; rarely required outside privileged containers |
| `CAP_SYS_PTRACE` | `process-control` | Only if app debugs/ptrace's other processes |
| `CAP_SYS_NICE` | `process-control` | For changing scheduling priority |

---

## Filesystem capabilities

| Capability | Snap interface / construct | Notes |
|---|---|---|
| `CAP_DAC_OVERRIDE` | *(drop — usually not needed in strict snap)* | Bypass file permission checks; not grantable via standard interface |
| `CAP_DAC_READ_SEARCH` | *(drop — use layouts instead)* | If needed only to read specific files, use snap `layout` to expose them |
| `CAP_CHOWN` | *(restricted under strict confinement — use `chmod` instead)* | Root inside a strict snap **cannot** `chown` files to a different UID/GID; the AppArmor profile denies `CAP_CHOWN` for foreign UIDs. `chown _daemon_:root "$DIR"` silently fails or returns `Permission denied`. Use `chmod go+rwX` to grant a privilege-dropped user access to root-owned dirs. Ownership changes between snap-owned paths (root→root) work normally |
| `CAP_FOWNER` | *(none — default within snap)* | Available for snap-owned files |
| `CAP_FSETID` | *(none — default within snap)* | Set-UID/set-GID bits |
| `CAP_MKNOD` | `device-control` | Create device nodes; requires store review |
| `CAP_SYS_CHROOT` | *(drop — not grantable)* | Use snap's own mount namespace instead |
| `CAP_LINUX_IMMUTABLE` | *(drop — not grantable)* | Immutable flag on files |
| `CAP_LEASE` | *(drop — rarely needed)* | File leases |

---

## System / kernel capabilities

| Capability | Snap interface / construct | Notes |
|---|---|---|
| `CAP_SYS_ADMIN` | `system-observe` or custom confinement | Very broad; avoid if possible; requires store review |
| `CAP_SYS_BOOT` | *(not grantable via interface)* | Reboot; not available in strict confinement |
| `CAP_SYS_MODULE` | *(not grantable via interface)* | Load kernel modules; requires classic confinement |
| `CAP_SYS_RAWIO` | `raw-io` | Raw I/O port access |
| `CAP_SYS_TIME` | `time-control` | Set system clock |
| `CAP_SYS_RESOURCE` | *(drop — usually not needed)* | Override resource limits |
| `CAP_SYS_TTY_CONFIG` | `tty-control` | Virtual console configuration |

---

## Audit capabilities

| Capability | Snap interface / construct | Notes |
|---|---|---|
| `CAP_AUDIT_WRITE` | *(drop — not needed in most snaps)* | Write to kernel audit log. This is a common OCI container default that snaps do **not** need. Drop unless the application explicitly calls `audit_log()` / `libaudit`. No snap interface exposes this |
| `CAP_AUDIT_CONTROL` | *(not grantable via interface)* | Change audit rules; requires classic confinement |
| `CAP_AUDIT_READ` | *(not grantable via interface)* | Read audit log; requires classic confinement |

---

## IPC & device capabilities

| Capability | Snap interface / construct | Notes |
|---|---|---|
| `CAP_IPC_LOCK` | `ipc` | Lock memory (mlock) |
| `CAP_IPC_OWNER` | `ipc` | Bypass IPC permission checks |
| `CAP_SYS_PACCT` | *(drop)* | Process accounting; rarely needed |
| `CAP_BLOCK_SUSPEND` | `block-devices` or `power-control` | Depends on exact usage |

---

## Capabilities that cannot be granted via interfaces

These capabilities require **classic confinement** or a **store security exception**.
Document them in the output and flag as needing manual review:

- `CAP_SYS_MODULE` (kernel module loading)
- `CAP_SYS_BOOT` (rebooting the system)
- `CAP_AUDIT_CONTROL` (modifying audit rules)
- `CAP_AUDIT_READ` (reading raw audit log)
- `CAP_SYS_CHROOT` (use snap namespacing instead)

---

## Decision algorithm

```
For each capability in config.json:
  1. Look up the capability in this table.
  2. If "none — default within snap": no plug needed, skip.
  3. If "drop — usually not needed": omit and note why.
  4. If a snap interface name is listed: add `plugs: [<interface>]` to the app in snapcraft.yaml.
  5. If "not grantable via interface": flag for store review or consider classic confinement.
```
