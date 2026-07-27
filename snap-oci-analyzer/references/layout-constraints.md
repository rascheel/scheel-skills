# Snap Layout Constraints

Source: https://documentation.ubuntu.com/snapcraft/stable/reference/layouts/#requirements

This file is the authoritative reference for what is and is not allowed as a
layout target path. The analysis checklist and patch script both enforce these
rules. Consult this file whenever a path candidate is identified in Phase 4–5.

---

## Table of Contents
1. [Hard rules](#1-hard-rules)
2. [Forbidden target paths (explicit list)](#2-forbidden-target-paths-explicit-list)
3. [Decision: is this layout target valid?](#3-decision-is-this-layout-target-valid)
4. [Workarounds for forbidden targets](#4-workarounds-for-forbidden-targets)
5. [Like-for-like replacement rule](#5-like-for-like-replacement-rule)

---

## 1. Hard rules

All four rules must be satisfied simultaneously. Violating any one of them
means the layout entry **cannot be used** and an alternative approach is required.

| # | Rule | Example violation |
|---|---|---|
| 1 | **Strictly-confined only** — layouts do not work in classically-confined snaps | N/A for most IoT / packaged apps |
| 2 | **No forbidden target paths** — the explicit denylist in §2 below | `layout: /proc` |
| 3 | **No root-level target paths** — the target must not be a direct child of `/` | `layout: /nix`, `layout: /certs`, `layout: /docker-entrypoint-initdb.d` |
| 4 | **Like-for-like replacement** — a directory must map to a directory; a file to a file; you cannot replace a directory with a symlink | Mapping a file path with `bind:` (directory) instead of `bind-file:` |

> ⚠️ **Runtime discovery warning:** Forbidden path restrictions are enforced by
> `snapd` at runtime, not at build time. A snap that declares a forbidden layout
> will install and pack successfully but **fail to start** — the service log will
> show an error from `snap-confine` like `cannot create layout /foo: ...`. This
> means forbidden-path problems are NOT caught by `snapcraft pack` or
> `snapcraft --use-lxd --build-for <target_arch>`. Always check layouts against
> this document before testing.

> ⚠️ **Common OCI pitfall — new top-level directories:** Many Docker entrypoint
> scripts create or reference top-level directories like `/docker-entrypoint-initdb.d`
> that do not exist on a standard Linux system. These are FORBIDDEN as layout
> targets (rule 3: direct child of `/`). Patch the entrypoint script to reference
> `$SNAP_COMMON/<directory>` instead, and create the directory in the install hook.

> ⚠️ **`/var/run/` is always forbidden:** Even though `/var/run/postgresql` (or
> similar) may appear valid at first glance (depth 3, not literally `/run`), it is
> explicitly in the denylist via `/var/run`. Patch the application config or
> entrypoint to use `$SNAP_DATA/run` or `$SNAP_COMMON/run` instead.

---

## 2. Forbidden target paths (explicit list)

The entries below are **always forbidden**, including **any path that begins with
one of these prefixes** (i.e. any subdirectory thereof). For example, `/home` being
forbidden also makes `/home/root`, `/home/user/.config/myapp`, etc. all forbidden.
The `patch_snapcraft.py` script rejects any layout whose target exactly matches or
starts with a path in this list.

```
/boot
/dev
/home
/lib/firmware
/usr/lib/firmware
/lib/modules
/usr/lib/modules
/lost+found
/media
/proc
/run
/var/run
/sys
/tmp
/var/lib/snapd
/var/snap
```

---

## 3. Decision: is this layout target valid?

```
Given a candidate target path T:

1. Does T exactly match, or start with, any path in the forbidden list above?
      YES → FORBIDDEN. See §4 for workarounds.

2. Is T a direct child of '/'?
   (i.e., T has exactly one path component, e.g. /nix, /certs, /data)
      YES → FORBIDDEN. See §4 for workarounds.

3. Is T a directory? Ensure the source is also a directory (use bind:).
   Is T a file?      Ensure the source is also a file (use bind-file:).
   Mismatch?         → INVALID. Adjust the layout type.

4. All checks pass → layout is valid.
```

### Quick reference — common paths from OCI images

| Target path | Verdict | Reason |
|---|---|---|
| `/nix` | ❌ FORBIDDEN | Direct child of `/` (rule 3) |
| `/certs` | ❌ FORBIDDEN | Direct child of `/` (rule 3) |
| `/data` | ❌ FORBIDDEN | Direct child of `/` (rule 3) |
| `/proc` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/run` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/run/myapp` | ❌ FORBIDDEN | Subdirectory of `/run` in denylist (rule 2) |
| `/tmp` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/var/run` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/home` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/home/root` | ❌ FORBIDDEN | Subdirectory of `/home` in denylist (rule 2) |
| `/usr/lib/softhsm` | ✅ VALID | Depth ≥ 2, not in denylist |
| `/usr/lib/firmware` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/var/lib/softhsm` | ✅ VALID | Depth ≥ 2, not in denylist |
| `/etc/myapp` | ✅ VALID | Depth ≥ 2, not in denylist |
| `/var/lib/snapd` | ❌ FORBIDDEN | Explicit denylist (rule 2) |
| `/usr/share/myapp` | ✅ VALID | Depth ≥ 2, not in denylist |

---

## 4. Workarounds for forbidden targets

The `scripts/patch_snapcraft.py` script **warns and skips** any layout whose
target fails validation — it never hard-errors on a forbidden path. The
remaining valid layouts are still applied.

**Example output for a forbidden target:**

```
WARNING: Skipping layout '/run/myapp' — invalid target path:
  '/run/myapp': in the snapcraft layouts denylist.
  If the application lets you configure this path (e.g. via an
  environment variable or config file), you can ignore this warning
  and redirect the path at runtime instead:
    - For writable paths: point to $SNAP_COMMON/<subpath> (persists
      across upgrades) or $HOME/<subpath> (per-user, needs home plug).
    - For read-only paths shipped in the snap: point to $SNAP/<subpath>.
  Otherwise, consult references/layout-constraints.md for alternatives.
```

When a path is skipped, report it to the user and apply the workaround below
that matches the path's prefix.

---

### 4a. Paths under `/home/`

The entire `/home/` subtree is forbidden for layouts — including `/home/root` and
any other subdirectory. **No layout can redirect a path under `/home/`.**

The correct approach is to use the `home` snap interface, which grants the snap
access to the user's home directory (`$HOME`), and configure the application to
write there instead of the hardcoded path.

**Steps:**

1. Add the `home` plug to the app in `snapcraft.yaml`:

   ```yaml
   apps:
     myapp:
       plugs:
         - home
   ```

2. In the snap wrapper script, redirect the hardcoded path to `$HOME/<subpath>`:

   ```bash
   export MYAPP_CONFIG_DIR="$HOME/.config/myapp"
   export MYAPP_DATA_DIR="$HOME/.local/share/myapp"
   mkdir -p "$MYAPP_CONFIG_DIR" "$MYAPP_DATA_DIR"
   exec "$SNAP/bin/myapp" "$@"
   ```

   Alternatively, use snap-managed per-user directories:
   - `$SNAP_USER_DATA` — per-user, per-revision (wiped on refresh)
   - `$SNAP_USER_COMMON` — per-user, persists across revisions (preferred for config/data)

3. After installing, connect the plug:

   ```bash
   snap connect myapp:home
   ```

   > On desktop systems the `home` interface auto-connects for user-installed
   > snaps. On server / IoT systems it requires a manual `snap connect` call or a
   > store auto-connect assertion.

---

### 4b. All other forbidden paths

For paths in the denylist (e.g. `/run`, `/tmp`, `/proc`) or root-level targets
(e.g. `/nix`, `/data`) that are **not** under `/home/`:

Configure the application at runtime to use an explicit `$SNAP_COMMON/<path>`
instead of the hardcoded location. Apply the first option that works:

| Option | How |
|---|---|
| **Environment variable** | Export the redirect in the snap wrapper script (e.g. `export MYAPP_DATA_DIR="$SNAP_COMMON/data"`) |
| **Config file flag** | Pass a CLI flag or config entry that overrides the default path on startup |
| **Build-time patch** | Use `patchelf --replace-needed` or patch the source to remove the hardcoded prefix |

If none of the above is feasible, document the path in the "unmappable paths"
output section and note that the application may require classic confinement or
a store exception.

---

## 5. Like-for-like replacement rule

| Source is a… | Use layout type |
|---|---|
| Directory | `bind: <source-path>` |
| Single file | `bind-file: <source-path>` |
| Symlink target | `symlink: <source-path>` |
| Ephemeral scratch | `tmpfs:` (no source needed) |

Snapd will **reject** a snap at install time if a layout tries to replace a
directory with a file or vice versa.
