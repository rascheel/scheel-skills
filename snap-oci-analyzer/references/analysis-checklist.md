# OCI → Snap Analysis Checklist

Step-by-step checklist for converting an OCI container runtime specification
(`config.json` + `rootfs/`) into `snapcraft.yaml` interface plugs and layout
directives. Work through each phase in order.

---

## Table of Contents
1. [Phase 1 — Gather inputs](#phase-1--gather-inputs)
2. [Phase 2 — Map capabilities to interfaces](#phase-2--map-capabilities-to-interfaces)
3. [Phase 3 — Map mounts to snap constructs](#phase-3--map-mounts-to-snap-constructs)
4. [Phase 4 — Inspect binary and rootfs for hardcoded paths](#phase-4--inspect-binary-and-rootfs-for-hardcoded-paths)
5. [Phase 5 — Classify paths as layout or $SNAP_COMMON](#phase-5--classify-paths-as-layout-or-snap_common)
6. [Phase 6 — Produce output](#phase-6--produce-output)

---

## Phase 1 — Gather inputs

- [ ] Locate `config.json` (OCI runtime spec, typically alongside `rootfs/`).
- [ ] Identify the main executable from `config.json → process.args[0]`.
- [ ] Locate the actual binary inside `rootfs/` (follow symlinks if needed).
- [ ] Note the target architecture from `annotations["org.opencontainers.image.architecture"]`.
- [ ] Extract `config.json → process.user` (uid/gid/username):
  - If `uid: 0` or absent → the container runs as root. No user-related action needed.
  - If `uid` is **non-zero** or `username` is a non-root user → the application
    requires privilege separation. Flag this for the **system-usernames check** below.
  - This may also hint at capabilities truly needed vs. container defaults (e.g. if the
    container already drops to a non-root user, `CAP_NET_BIND_SERVICE` may not be needed).

### Non-root user check (only if `process.user.uid ≠ 0`)

When the OCI process runs as a non-root user, snapping it requires `system-usernames`
because snap daemons always start as root. The key question is whether the user is
configurable:

- [ ] Search the rootfs for user-configuration mechanisms:
  ```bash
  # CLI flags
  strings rootfs/<binary> | grep -iE '(--user|--group|--run-as|--uid|--gid)' | head -20
  # Env vars
  strings rootfs/<binary> | grep -oE '[A-Z][A-Z0-9_]{3,}_(USER|GROUP|UID|GID)' | sort -u
  # Config file keys
  grep -rE '^\s*(user|group|run_as|runas|uid|gid)\s*[=:]' rootfs/etc/ 2>/dev/null | head -20
  ```
- [ ] Based on the result, record the configurability:
  - **Configurable** (env var / config key / CLI flag) → set it to `_daemon_` in the wrapper
    or via an `override-build` config mutation.
  - **Not configurable** → use a `setpriv` wrapper to drop privileges before exec.
- [ ] Record the chosen method — it will be encoded as an override step in Phase 4b
  of the main `snap-oci-container` workflow.
- [ ] See `references/system-usernames-guide.md` for the complete decision tree,
  YAML syntax, and wrapper patterns.

### Entrypoint script check (when `process.args[0]` is a shell script)

Shell-based entrypoints often contain `export VAR=/hardcoded/path` lines that
unconditionally overwrite values the snap launch wrapper sets — causing the
wrapper's `$SNAP`/`$SNAP_COMMON` redirections to be silently discarded at
runtime:

```bash
# Scan the entrypoint and any scripts it sources for hardcoded absolute exports
entrypoint=$(jq -r '.process.args[0]' config.json | sed 's|^\./||')
grep -nE '^export [A-Z_]+=/[a-z]' rootfs/$entrypoint 2>/dev/null
# Also check scripts sourced by the entrypoint (e.g. an env-setup script, or an initdb.d-style directory)
find rootfs -name "*.sh" -exec grep -lE '^export [A-Z_]+=/[a-z]' {} \;
```

- [ ] For each hardcoded `export VAR=/path` found: record the variable name.
- [ ] Add an `override-build` `sed` step (see `references/override-steps-guide.md §5`)
  that rewrites `export VAR=/path` → `export VAR="${VAR:-/path}"` so a
  pre-set value from the snap wrapper is honoured at runtime.

### Verify the generated `library_wrapper.sh`

After `docker-to-snap --suppress-build` completes, immediately inspect the
generated wrapper to confirm the `ENTRYPOINT=` line resolves to a real path:

```bash
grep 'ENTRYPOINT=' <output-folder>/snap/local/library_wrapper.sh 2>/dev/null || \
  grep 'ENTRYPOINT=' <output-folder>/usr/bin/library_wrapper.sh 2>/dev/null
```

- [ ] Confirm the resolved path exists inside `rootfs/`:
  `ls rootfs/<resolved-path>`
- [ ] If the path is wrong (e.g. a `/usr/local/bin/` fallback for an entrypoint
  that lives elsewhere), replace `library_wrapper.sh` with a custom wrapper
  that sets `ENTRYPOINT` directly to the correct `$SNAP/<real-path>`.

> **Common cause of wrong resolution:** when `process.args[0]` is a
> cwd-relative path like `./entrypoint.sh`, `create_wrapper.sh` searches the
> container PATH and, if the script is not on PATH, falls back to the
> `process.cwd` + entrypoint name. Verify the resulting path is the intended
> one. Absolute `process.args[0]` values (starting with `/`) are always
> resolved correctly.

---

## Phase 2 — Map capabilities to interfaces

Read `config.json → process.capabilities` (all five sets: bounding, effective,
permitted, inheritable, ambient).

For each unique capability, consult `references/capability-interface-map.md`:

- [ ] Record capabilities that map to a snap interface plug (add to plug list).
- [ ] Record capabilities that are **auto-granted** (no plug needed — note this).
- [ ] Record capabilities that are OCI container defaults and should be **dropped** in a snap (e.g. `CAP_AUDIT_WRITE`).
- [ ] Flag any capability that requires classic confinement or a store exception.

**Key rule:** If a capability only exists because the OCI runtime grants it by
default (not because the application actually calls the syscall), it can and
should be dropped in strict confinement.

---

## Phase 3 — Map mounts to snap constructs

Read `config.json → mounts`. For each entry, consult
`references/mount-snap-map.md`:

- [ ] Identify **auto-provided** mounts (no action needed — tick and skip).
- [ ] Identify mounts that require a **snap interface plug** (e.g. device nodes, DNS).
- [ ] Identify bind mounts that require a **layout** entry.
  - For each bind mount layout, decide the target:
    - Read-only, ships inside the snap → `$SNAP/<subpath>`
    - Writable at runtime → `$SNAP_COMMON/<subpath>`
    - Writable, ephemeral → `$XDG_RUNTIME_DIR/<subpath>` or `$SNAP_DATA/run/<subpath>`

---

## Phase 4 — Inspect binary and rootfs for hardcoded paths

This phase finds paths that are **not** in `config.json` but are compiled into
the binary or shipped in the image.

### 4a. List rootfs structure
```bash
find rootfs/ -not -type d | sort
```
- [ ] Note the top-level directories (e.g. `/nix`, `/usr`, `/lib`, `/etc`).
- [ ] Identify any non-standard prefix (e.g. `/nix/store/…` from Nix builds).
- [ ] Note any config files, certificates, or database files that need to be writable.

### 4b. Resolve symlinks for the main binary
```bash
ls -la rootfs/bin/<appname>
readlink -f rootfs/bin/<appname>
```
- [ ] Record the real binary path inside `rootfs/`.

### 4c. Extract filesystem paths from the binary
```bash
strings rootfs/<real-binary-path> | grep -oE '(/[a-zA-Z0-9._-]+){2,}' \
  | grep -v '/rust/' | grep -v '/rustc/' | sort -u
```
- [ ] Record all paths that look like runtime file accesses (ignore build-time source paths).

### 4d. Extract ELF interpreter and RUNPATH
```bash
readelf -p .interp rootfs/<real-binary-path>
readelf -d rootfs/<real-binary-path> | grep -E '(NEEDED|RUNPATH|RPATH)'
```
- [ ] Record the ELF interpreter path (e.g. `/nix/store/<hash>/lib/ld-linux-aarch64.so.1`).
- [ ] Record all RUNPATH directories (shared library search paths baked in at link time).
- [ ] Note any hardcoded prefix paths (e.g. a build-system-specific store location).

### 4e. Extract environment variable names from the binary
```bash
strings rootfs/<real-binary-path> | grep -oE '[A-Z][A-Z0-9_]{3,}' | sort -u | head -40
```
- [ ] Note env vars that configure file paths (e.g. `<APP>_CONFIG_PATH`, `<APP>_DATA_DIR`, `<APP>_TLS_CERT`).
- [ ] These will need to be set in a wrapper script pointing into `$SNAP` or `$SNAP_COMMON`.

### 4f. Inspect entrypoint and launch scripts for hardcoded path exports

When `process.args[0]` is a shell script, it may contain `export VAR=/hardcoded/path`
lines that run **after** the snap launch wrapper has already set the correct
`$SNAP`/`$SNAP_COMMON` values — silently discarding them. These are invisible
to `strings` on the ELF binary and require direct script inspection.

```bash
# Find shell scripts that export hardcoded absolute paths
find rootfs -name "*.sh" -exec grep -lE '^export [A-Z_]+=/[a-z]' {} \;
# Inspect each found script
grep -nE '^export [A-Z_]+=/[a-z]' rootfs/<script-path>
```

- [ ] For each hardcoded export found: record the variable name and value.
- [ ] Determine whether the snap wrapper can pre-set the variable to the correct
  `$SNAP`/`$SNAP_COMMON` path **before** the entrypoint script runs:
  - **Yes** → add an `override-build` `sed` step that rewrites
    `export VAR=/path` → `export VAR="${VAR:-/path}"` so the wrapper's
    pre-set value is honoured. See `references/override-steps-guide.md §5`.
  - **No** (path used for a different purpose, or inside a conditional) →
    investigate layout or wrapper `cd` to the expected directory.

---

## Phase 5 — Classify paths as layout or $SNAP_COMMON

For each path found in Phase 4, apply this decision tree:

```
Is the path's content shipped inside the snap image (rootfs)?
  YES → Does the app write to this path at runtime?
          YES → layout: bind: $SNAP_COMMON/<subpath>  (writable, persists across upgrades)
          NO  → layout: bind: $SNAP/<subpath>          (read-only from snap content)
  NO  → Is the content provisioned by the operator post-install (e.g. TLS certs)?
          YES → layout: bind: $SNAP_COMMON/<subpath>  (operator writes here manually)
          NO  → Is the content ephemeral / generated at runtime?
                  YES → layout: bind: $XDG_RUNTIME_DIR/<subpath>  (cleared on reboot)
                  NO  → Investigate further — may need a plug or classic confinement
```

### ⚠️ Validate each candidate layout target against the constraints

**Before recording a path as a layout**, check it against
`references/layout-constraints.md` (or rely on `scripts/patch_snapcraft.py`,
which warns and skips any forbidden target rather than failing):

1. Is the target in the explicit denylist?  → **forbidden**, investigate workaround.
2. Is the target a direct child of `/` (one path component)?  → **forbidden**, investigate workaround.
3. Both checks pass → layout is valid.

Forbidden paths are reported by the script as WARNINGs; the user should
address them manually based on how the application exposes configuration.

### Common path patterns

| Path pattern | Typical classification | Snap target | Valid? |
|---|---|---|---|
| `/usr/lib/<libname>/` | Shared library (ships in snap) | `layout: /usr/lib/<libname>: bind: $SNAP/lib/<libname>` | ✅ |
| `/etc/<app>/` config (RO) | Bundled default config | `layout: /etc/<app>: bind: $SNAP/etc/<app>` | ✅ |
| `/etc/<app>/` config (RW) | Operator-configured | `layout: /etc/<app>: bind: $SNAP_COMMON/etc/<app>` | ✅ |
| `/var/lib/<app>/` | Application state DB | `layout: /var/lib/<app>: bind: $SNAP_COMMON/<app>` | ✅ |
| `/etc/myapp/certs/` | TLS certs exposed via deeper path | `layout: /etc/myapp/certs: bind: $SNAP_COMMON/certs` | ✅ |
| `/<name>/` (one component) | Any root-level custom dir | Forbidden — investigate env-var override or build-time patching | ❌ root-level |
| `/run/<app>/` | Runtime socket / PID file | Forbidden — `/run` is in denylist | ❌ denylist |
| `/tmp/<app>/` | Temporary scratch | Forbidden — `/tmp` is in denylist | ❌ denylist |

For every forbidden case, see `references/layout-constraints.md §2–4`.

---

## Phase 6 — Produce output

Assemble the findings into two sections:

### 6a. Rationale table
Produce a markdown table mapping each OCI item to its snap construct:

| OCI item | Type | Snap construct | Rationale |
|---|---|---|---|
| `CAP_NET_BIND_SERVICE` | capability | `plugs: [network-bind]` | Bind to ports < 1024 |
| `/proc` mount | mount | auto-provided | snapd mounts proc in all snaps |
| `/etc/resolv.conf` mount | mount | `plugs: [network]` | DNS resolution via network interface |
| `/usr/lib/<libname>` | library path | `layout: /usr/lib/<libname>: bind: $SNAP/lib/<libname>` | Path baked at build time |
| … | … | … | … |

### 6b. snapcraft.yaml snippet
Use `assets/snapcraft-snippet-template.yaml` as the base. Populate:
- `plugs:` list under the app or at top level
- `layout:` section with all discovered path mappings

### 6c. Wrapper script hints
For each env var that configures a path (Phase 4e), note the export statement
needed in the snap wrapper script, e.g.:

```bash
#!/bin/bash
# Redirect config/data paths discovered in Phase 4e to writable locations.
export <APP>_CONFIG_PATH="$SNAP_COMMON/config"
export <APP>_DATA_DIR="$SNAP_COMMON/data"
mkdir -p "$<APP>_CONFIG_PATH" "$<APP>_DATA_DIR"
exec "$SNAP/bin/<appname>" "$@"
```

Replace `<APP>` and `<appname>` with the actual application identifiers.
Add `mkdir -p` calls for any directories the app needs to exist before launch.
