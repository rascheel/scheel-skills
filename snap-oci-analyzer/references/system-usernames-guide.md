# System Usernames — Non-Root Service User Guide

When an OCI container specifies a non-root `process.user`, the application
likely needs to run as a specific user for security or functionality reasons.
Inside a snap, all daemons start as **root** (launched by systemd). The
`system-usernames` snapcraft feature is the correct mechanism for running a
snap service as a non-root user.

Reference: https://snapcraft.io/docs/explanation/snap-development/system-usernames

---

## Table of Contents

1. [Detection: is system-usernames needed?](#1-detection)
2. [Snapcraft YAML syntax](#2-snapcraft-yaml-syntax)
3. [Configurability check](#3-configurability-check)
4. [Privilege-drop methods](#4-privilege-drop-methods)
5. [Ownership and file access](#5-ownership-and-file-access)
6. [Signal handling](#6-signal-handling)
7. [snapcraft.yaml snippet](#7-snapcraft-yaml-snippet)
8. [gosu / su-exec re-exec shebang crash](#8-gosu-su-exec-re-exec-shebang-crash)
9. [/etc/passwd inode problem in core-base snaps](#9-etcpasswd-inode-problem-in-core-base-snaps)

---

## 1. Detection

Check `config.json → process.user`:

```bash
python3 -c "import json; c=json.load(open('config.json')); print(c.get('process',{}).get('user',{}))"
```

| `process.user` value | Interpretation |
|---|---|
| `{}` or absent, or `uid: 0` | Container runs as root — no action needed for user |
| `uid: <non-zero>` or `username: <non-root>` | App requires a non-root user → apply this guide |

**If the container runs as a non-root user**, proceed to §3 (configurability check)
to determine the correct approach.

---

## 2. Snapcraft YAML Syntax

Add the `system-usernames` stanza at the top level of `snapcraft.yaml`.

**Recommended (snapd ≥ 2.61):**
```yaml
system-usernames:
  _daemon_: shared
```
`_daemon_` has UID/GID `584792`. It is the preferred name from snapd 2.61 onwards.

**Legacy (snapd < 2.61):**
```yaml
system-usernames:
  snap_daemon: shared
```
`snap_daemon` has UID/GID `584788`. Still functional; deprecated in favour of
`_daemon_`.

`shared` is the only currently supported scope.

**Decision:** Unless you know the deployment targets only pre-2.61 snapd, use
`_daemon_`. If broad compatibility is required, use `snap_daemon` — it still
works on new snapd versions.

---

## 3. Configurability Check

The application can adopt `system-usernames` only if the **user it runs as is
configurable** — i.e. the snap can tell the application to use `snap_daemon` /
`_daemon_` instead of its original container user.

### How to detect configurability

Search the rootfs for user configuration mechanisms:

```bash
# 1. CLI flag hints
strings rootfs/$(readlink -f rootfs/<binary-path> | sed 's|rootfs/||') \
  | grep -iE '(--user|--group|--run-as|--uid|--gid)' | head -20

# 2. Environment variable hints
strings rootfs/<real-binary-path> \
  | grep -oE '[A-Z][A-Z0-9_]{3,}_(USER|GROUP|UID|GID)' | sort -u

# 3. Config file inspection — look for user/group keys
grep -rE '^\s*(user|group|run_as|runas|uid|gid)\s*[=:]' rootfs/etc/ 2>/dev/null | head -20

# 4. Check OCI entrypoint wrapper scripts
find rootfs/ -name '*.sh' -exec grep -l 'user\|setuid\|setpriv' {} \;
```

### Decision tree

```
Does the application accept a configurable user?
  │
  ├─ YES (env var, config file, or CLI flag) ─────────────────────────────┐
  │                                                                        │
  │   → Add system-usernames to snapcraft.yaml (§2)                       │
  │   → Set the user in the wrapper script or config (§4a)                │
  │   → Adjust file ownership as needed (§5)                              │
  │                                                                        │
  └─ NO (user is hardcoded in the binary) ────────────────────────────────┤
                                                                          │
      → Add system-usernames to snapcraft.yaml (§2)                      │
      → Use setpriv in the wrapper script to drop privileges (§4b)       │
      → The binary will see itself running as snap_daemon / _daemon_      │
```

---

## 4. Privilege-Drop Methods

### 4a. Application-managed drop (configurable user)

If the application reads a user from a config file or environment variable,
set it to the system-usernames user in the wrapper script or config override:

**Via environment variable (wrapper script):**
```bash
#!/bin/bash
# Wrapper script: set the run-as user to the snap system-usernames user.
export APP_RUN_AS_USER="_daemon_"
export APP_RUN_AS_GROUP="_daemon_"
exec "$SNAP/usr/bin/myapp" "$@"
```

**Via config file mutation (`override-build`):**
```yaml
override-build: |
  snapcraftctl build
  sed -i 's/^user\s*=.*/user = _daemon_/' \
    $SNAPCRAFT_PART_INSTALL/etc/myapp/myapp.conf
```

### 4b. setpriv wrapper (non-configurable user)

When the binary's user is hardcoded or the application calls `setuid`/`setgid`
itself using the original container UID, wrap the binary with `setpriv` to
drop privileges to the system-usernames user **before** exec:

```bash
#!/bin/bash
# Wrapper: drop privileges to _daemon_ before executing.
exec "$SNAP/usr/bin/setpriv" \
  --clear-groups \
  --reuid _daemon_ \
  --regid _daemon_ \
  -- "$SNAP/usr/bin/myapp" "$@"
```

**Stage `setpriv` in the snap** (it ships with `util-linux` for core20/core22/core24):
```yaml
parts:
  oci-container:
    plugin: dump
    source: rootfs/
    stage-packages:
      - util-linux   # provides setpriv; add only if not already in rootfs
```

**If the application uses `initgroups()` internally** (which calls `setgroups`
in a way the sandbox blocks), use LD_PRELOAD alongside `setpriv`:
```bash
LD_PRELOAD="$SNAP_COMMON/wraplib.so" \
exec "$SNAP/usr/bin/setpriv" \
  --clear-groups \
  --reuid _daemon_ \
  --regid _daemon_ \
  -- "$SNAP/usr/bin/myapp" "$@"
```

### 4c. Native setuid / setgid (application drops privileges itself)

If the application already calls `setgroups(0, NULL)` + `setgid()` + `setuid()`
correctly (using the user looked up from `getpwnam()`), it will work
automatically once `system-usernames` provides the `snap_daemon` / `_daemon_`
username:

```yaml
system-usernames:
  _daemon_: shared
```

The application calls `getpwnam("_daemon_")` → receives UID 584792 → drops to
it. No wrapper changes needed beyond configuring the application to use the
correct username (§4a).

---

## 5. Ownership and File Access

After privilege drop, the snap security sandbox limits file access to objects
owned by the running UID — **even for root**, unless `CAP_DAC_OVERRIDE` is
present (which strict confinement denies).

### Writable directories

> **⚠️ AppArmor `CAP_CHOWN` restriction:** Under strict confinement the
> AppArmor profile does **not** grant `CAP_CHOWN` for foreign UIDs. Root inside
> the snap **cannot** `chown` files to `_daemon_` (or any other UID that differs
> from root). `chown _daemon_:root "$DIR"` will silently fail or return
> `Permission denied` even when called from the daemon wrapper running as root.
> Do **not** use `chown` in snap wrapper scripts to grant access to a
> system-username user.

**Use `chmod` instead.** Root can always chmod files it owns — no capability
required. Make directories group- and other-accessible so the privilege-dropped
user can read and write them without a `chown`:

```bash
# In the launch wrapper (runs as root before setpriv drop):
DATA_DIR="$SNAP_COMMON/myapp"
mkdir -p "$DATA_DIR"
# chmod lets _daemon_ traverse and write; chown would silently fail.
chmod go+rwX "$DATA_DIR"   # grant group+other read/write/traverse
```

For a writable tree seeded from read-only snap defaults on first boot:
```bash
mkdir -p "$DATA_DIR" "$LOGS_DIR" "$CONF_DIR"
chmod -R go+rwX "$DATA_DIR" "$LOGS_DIR" "$CONF_DIR"
```

> **Note:** `chmod go+rwX` grants access regardless of whether `_daemon_`'s GID
> matches the file group. It relies on the snap sandbox (AppArmor + seccomp +
> mount namespace) as the security boundary, which is the correct trust model
> for strict confinement.

If the OCI image ships config directories with mode `700` (root-only), patch
them to at least `755` at build time so the dropped user can traverse them after
the privilege drop:

```yaml
override-build: |
  snapcraftctl build
  # Fix root-700 config dirs so _daemon_ can traverse them after privilege drop.
  find $SNAPCRAFT_PART_INSTALL/etc/myapp -type d -exec chmod 755 {} \;
```

### Read-only files shipped in the snap

Files under `$SNAP` are owned by root. The privilege-dropped user can read them
as long as the unix permissions include group/other read bits (mode `644`/`755`
— the standard for files shipped in a snap). No ownership change is needed.

---

## 6. Signal Handling

The snap sandbox only allows processes with the **same owner** to signal each
other (unless `CAP_KILL` is present). After privilege drop:

- Root-owned management processes **cannot** signal `_daemon_`-owned worker
  processes without first dropping their own privileges.
- Either drop privileges **before** sending signals, or add `plugs: [process-control]`
  (grants `CAP_KILL` — requires store review).

**Best practice:** Drop privileges before signal-sending; avoid `process-control`
unless absolutely necessary.

---

## 7. snapcraft.yaml Snippet

Complete minimal snippet combining `system-usernames` with a daemon app:

```yaml
# Top-level — add alongside name/version/summary
system-usernames:
  _daemon_: shared      # use snap_daemon for snapd < 2.61 compatibility

apps:
  myapp:
    command: bin/wrapper.sh     # wrapper that drops to _daemon_ or configures user
    daemon: simple
    plugs:
      - network

parts:
  oci-container:
    plugin: dump
    source: rootfs/
    # If setpriv is needed and not already in rootfs:
    stage-packages:
      - util-linux
```

**Wrapper script (`snap/local/bin/wrapper.sh`):**
```bash
#!/bin/bash
set -e
exec "$SNAP/usr/bin/setpriv" \
  --clear-groups \
  --reuid _daemon_ \
  --regid _daemon_ \
  -- "$SNAP/usr/bin/myapp" "$@"
```

Add the wrapper as a separate part:
```yaml
parts:
  local-wrappers:
    plugin: dump
    source: snap/local/
    organize:
      bin/wrapper.sh: bin/wrapper.sh
    override-build: |
      snapcraftctl build
      chmod 755 $SNAPCRAFT_PART_INSTALL/bin/wrapper.sh
```

---

## 8. gosu / su-exec re-exec shebang crash

**Symptom:** The entrypoint script calls `exec gosu <user> "$BASH_SOURCE" "$@"` to
re-execute itself as the service user after initial setup. This triggers the kernel's
shebang parser (because `"$BASH_SOURCE"` is the script file itself). The shebang
`#!/usr/bin/env bash` causes the base snap's `/usr/bin/env` to run. If
`LD_LIBRARY_PATH` is set and the OCI image's glibc differs from the base snap's,
`/usr/bin/env` crashes immediately with `GLIBC_X.Y not found`.

**Why it happens:**
1. `exec gosu postgres "$BASH_SOURCE" "$@"` → gosu drops to the service user,
   then executes the script file by path.
2. The kernel reads the shebang `#!/usr/bin/env bash` and forks `env`.
3. `env` is from the BASE SNAP (core26/core24), not from the OCI rootfs.
4. `env` inherits `LD_LIBRARY_PATH` pointing at OCI libraries → glibc mismatch → SIGSEGV.

**Fix:** Bypass the kernel shebang parser entirely by passing the interpreter explicitly:

```bash
# Before (triggers kernel shebang parsing):
exec gosu postgres "$BASH_SOURCE" "$@"

# After (bypasses shebang — bash is from the OCI rootfs, not the base snap):
exec gosu postgres "$SNAP/usr/bin/bash" "$BASH_SOURCE" "$@"
```

**Important:** Use `$SNAP/usr/bin/bash` (the OCI rootfs bash), NOT `/bin/bash` or
`/usr/bin/bash` (which resolve to the base snap bash). The OCI bash has been linked
against the OCI libc and will work correctly with the OCI library paths.

**When to apply:** Search the entrypoint scripts for patterns like:
```bash
grep -n 'exec gosu\|exec su-exec\|exec su ' rootfs/usr/local/bin/docker-entrypoint.sh
```

If found, check whether the argument after the username is a script file (not a
binary). If it is a script, apply this fix as a `sed` patch in an `override-prime`
step or in the install hook logic.

---

## 9. /etc/passwd inode problem in core-base snaps

**Symptom:** An install hook creates the service user with `useradd`, but at runtime
the application reports `invalid user '<username>'` when calling `find -user postgres`
or similar utilities that look up usernames.

**Root cause (core26/core24 base):** The snap namespace sets up a `tmpfs` at `/etc`.
The `/etc/passwd` bind-mount captures the INODE of the file **at namespace setup time**.
When `useradd` in the install hook creates a new user, it uses `rename()` to atomically
replace `/etc/passwd` with a new file (new inode). All snap processes — including the
service daemon — see the OLD inode (the one captured by the bind-mount at startup) which
does not contain the newly created user.

**Solution: libnss_wrapper**

Use `libnss_wrapper.so` (from the OCI rootfs or from `libnss-wrapper` package) to
redirect all NSS username lookups to a temporary file that has been populated with
the correct user entries from the OCI image's own `/etc/passwd`.

```bash
# In library_wrapper.sh — before exec'ing the entrypoint:

# Create temp NSS files from the OCI's own /etc/passwd (which has the service user)
PASSWD_TMP=$(mktemp /tmp/nss_passwd_XXXXXX)
GROUP_TMP=$(mktemp /tmp/nss_group_XXXXXX)

grep -E '^(root|<serviceuser>):' "$SNAP/etc/passwd" > "$PASSWD_TMP"
grep -E '^(root|<servicegroup>):' "$SNAP/etc/group" > "$GROUP_TMP"

# CRITICAL: temp files must be world-readable (chmod 644) so that the service
# user (after gosu drops privileges) can still read them.
chmod 644 "$PASSWD_TMP" "$GROUP_TMP"

# CRITICAL: chown the temp files to the service user's UID so that cleanup
# (rm -f run by the service user after gosu drops privileges) succeeds.
service_uid=$(stat -c '%u' "$SNAP/home/<serviceuser>" 2>/dev/null || echo "999")
chown "$service_uid" "$PASSWD_TMP" "$GROUP_TMP"

export LD_PRELOAD="$SNAP/usr/lib/x86_64-linux-gnu/libnss_wrapper.so"
export NSS_WRAPPER_PASSWD="$PASSWD_TMP"
export NSS_WRAPPER_GROUP="$GROUP_TMP"
```

**Notes:**
- `libnss_wrapper.so` is typically present in Debian/Ubuntu OCI images (package
  `libnss-wrapper`). Check: `ls rootfs/usr/lib/x86_64-linux-gnu/libnss_wrapper.so`.
- If absent, add `libnss-wrapper` to `stage-packages` in `snapcraft.yaml`.
- The install hook still needs to create the user (`useradd`) so that tools on the
  HOST side (outside the snap namespace) that inspect users work correctly. The
  `libnss_wrapper` approach only fixes the SNAP NAMESPACE visibility issue.
- This issue is specific to `base: core26` / `base: core24` (and any base using
  kernel mount namespaces with tmpfs at `/etc`). It does not affect `base: bare`.
