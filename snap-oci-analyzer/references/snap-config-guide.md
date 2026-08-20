# Snap Configuration Guide: configure Hook, install Hook, and Config-File Wiring

This guide describes how to add user-facing configuration to an OCI-derived snap.
It covers option discovery, hook implementation, default config-file creation, and
wiring the config file into the application invocation.

---

## Table of Contents

1. [Identify configurable options](#1-identify-configurable-options)
2. [snapctl mechanics primer](#2-snapctl-mechanics-primer)
3. [install hook — create default config in `$SNAP_COMMON`](#3-install-hook--create-default-config-in-snap_common)
4. [configure hook — validate and apply options](#4-configure-hook--validate-and-apply-options)
5. [Wire the config file into the app invocation](#5-wire-the-config-file-into-the-app-invocation)
6. [snapcraft.yaml hooks stanza](#6-snapcraftyaml-hooks-stanza)
7. [Decision tree: env-var vs config-file](#7-decision-tree-env-var-vs-config-file)
8. [Validation patterns](#8-validation-patterns)
9. [Testing the hooks](#9-testing-the-hooks)
10. [Common mistakes and how to avoid them](#10-common-mistakes-and-how-to-avoid-them)

---

## 1. Identify configurable options

### 1.1 Sources of truth (use all that apply)

**OCI image documentation:**
- Docker Hub page for the image (`https://hub.docker.com/_/<name>` or equivalent)
- Upstream project README / docs site
- `ENTRYPOINT`/`CMD` arguments shown in the Dockerfile

**`config.json` environment variables:**
```bash
python3 -c "
import json
c = json.load(open('config.json'))
for e in c.get('process', {}).get('env', []):
    print(e)
"
```
Variables that look like tunables (not `PATH`, `HOME`, `TERM`, locale vars) are
candidate configuration options.

**`rootfs/` config file inspection:**
```bash
find rootfs/etc -name "*.conf" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" \
     -o -name "*.toml" -o -name "*.ini" 2>/dev/null | head -30
```
Read the discovered config files to identify which keys are relevant to an
operator and which are internal / should not be exposed.

**Caller-provided instructions:**
If the caller explicitly listed options to expose, use those as the canonical
set and supplement with the above research.

### 1.2 Categorize each option

For each candidate option, classify it:

| Category | Expose as snap config? | Notes |
|---|---|---|
| Port / bind address | Yes | Common need |
| Log level / verbosity | Yes | Useful for operators |
| TLS certificate paths | Yes | Point to `$SNAP_COMMON` |
| Resource limits (workers, connections) | Yes | Performance tuning |
| Data / state directory | No | Always `$SNAP_COMMON/<subpath>` — not user-settable |
| Internal service URLs (within the snap) | No | Fixed |
| Debug/developer flags | No | Not for production operators |

### 1.3 Choose snap config key names

Snap config keys must be lowercase, hyphenated, dot-namespaced.

| App env var or config key | Snap config key example |
|---|---|
| `PORT` | `port` |
| `LOG_LEVEL` | `log-level` |
| `MAX_CONNECTIONS` | `max-connections` |
| `TLS_CERT_FILE` | `tls.cert-file` |
| `TLS_KEY_FILE` | `tls.key-file` |
| `WORKER_COUNT` | `workers` |

---

## 2. snapctl mechanics primer

```bash
# Read a snap config value set by the operator
snapctl get <key>

# Read with a default if the key is not set
val=$(snapctl get <key>)
val="${val:-<default>}"

# Write a snap config value from within a hook
snapctl set <key>=<value>

# Restart the service after config change (daemon snaps only)
snapctl restart <snap-name>.<app-name>

# Stop / start a service
snapctl stop <snap-name>.<app-name>
snapctl start <snap-name>.<app-name>
```

**Hook locations (relative to snap project root):**
```
snap/hooks/install     # runs once on first install (and on re-install)
snap/hooks/configure   # runs on every `snap set` call
```

Both files must be executable (`chmod +x snap/hooks/install`, etc.).

In `snapcraft.yaml` the hooks are declared under the `hooks:` top-level key.
The `network-control` plug is required if the configure hook writes
`/etc/hosts` (standard for docker-to-snap generated hooks).

---

## 3. install hook — create default config in `$SNAP_COMMON`

The install hook runs once when the snap is first installed (and again on
re-install). Use it to:

1. Create writable directories under `$SNAP_COMMON`.
2. Write a default config file to `$SNAP_COMMON` **only if one does not already
   exist** (preserves operator customisations on re-install or refresh).
3. Write initial snap config keys that mirror the defaults.

### 3.1 Choosing `$SNAP_COMMON` vs `$SNAP_DATA`

| Variable | Survives snap upgrade? | Use for |
|---|---|---|
| `$SNAP_COMMON` | Yes — shared across revisions | Config files, databases, certs |
| `$SNAP_DATA` | No — revision-specific | Ephemeral run-time state |

Always use `$SNAP_COMMON` for config files and persistent state.

### 3.2 Default config file strategy

**Option A — Copy bundled default from `$SNAP`:**
Bundle a default config file in the snap (in `snap/local/` or copied from `rootfs/`)
and copy it to `$SNAP_COMMON` only on first install.

```bash
if [ ! -f "$SNAP_COMMON/config/<app>.conf" ]; then
    mkdir -p "$SNAP_COMMON/config"
    cp "$SNAP/etc/<app>/<app>.conf" "$SNAP_COMMON/config/<app>.conf"
fi
```

**Option B — Generate minimal default from snap config keys:**
Write a minimal config file from the current snap config values (which may be
defaults set during install).

```bash
mkdir -p "$SNAP_COMMON/config"
if [ ! -f "$SNAP_COMMON/config/<app>.conf" ]; then
    cat > "$SNAP_COMMON/config/<app>.conf" <<EOF
# <App> configuration — managed by snap hooks
# Edit snap options with: snap set <snap-name> <key>=<value>
port=8080
log-level=info
EOF
fi
```

### 3.3 Set initial snap config defaults

At the end of the install hook, set sensible defaults for all exposed snap
config keys so `snap get <snap-name>` shows meaningful values immediately:

```bash
snapctl set port=8080
snapctl set log-level=info
```

### 3.4 Template: `snap/hooks/install`

See `snap-packager/assets/install-hook-additions.sh` for a full template.

---

## 4. configure hook — validate and apply options

The configure hook runs every time the operator runs `snap set <snap-name> <key>=<value>`.
It must:

1. Read every exposed config key via `snapctl get`.
2. Validate each value (type, range, allowed values).
3. Exit non-zero with a descriptive message if validation fails — this causes
   `snap set` to reject the value and roll back.
4. Write valid values into the config file at `$SNAP_COMMON/config/<app>.conf`.
5. Restart the service (daemon snaps only) so the new config takes effect.

### 4.1 Validation rules

**Port numbers:**
```bash
port=$(snapctl get port)
if [ -n "$port" ]; then
    if ! echo "$port" | grep -qE '^[0-9]+$' || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "ERROR: 'port' must be an integer between 1 and 65535 (got: '$port')" >&2
        exit 1
    fi
fi
```

**Enumerated values (e.g. log level):**
```bash
log_level=$(snapctl get log-level)
if [ -n "$log_level" ]; then
    case "$log_level" in
        debug|info|warn|error|fatal) ;;
        *)
            echo "ERROR: 'log-level' must be one of: debug, info, warn, error, fatal (got: '$log_level')" >&2
            exit 1
            ;;
    esac
fi
```

**Positive integers:**
```bash
workers=$(snapctl get workers)
if [ -n "$workers" ]; then
    if ! echo "$workers" | grep -qE '^[1-9][0-9]*$'; then
        echo "ERROR: 'workers' must be a positive integer (got: '$workers')" >&2
        exit 1
    fi
fi
```

**File paths (must exist if set):**
```bash
cert_file=$(snapctl get tls.cert-file)
if [ -n "$cert_file" ] && [ ! -f "$cert_file" ]; then
    echo "ERROR: 'tls.cert-file' path does not exist: '$cert_file'" >&2
    exit 1
fi
```

### 4.2 Write validated values to the config file

After all validations pass, write all current (post-validation) values to the
config file. Use the current `snapctl get` value for each key; fall back to the
application's default where no value is set.

**Pattern for INI / key=value config files:**
```bash
# Re-read all keys (use defaults where not set)
port=$(snapctl get port); port="${port:-8080}"
log_level=$(snapctl get log-level); log_level="${log_level:-info}"
workers=$(snapctl get workers); workers="${workers:-4}"

mkdir -p "$SNAP_COMMON/config"
cat > "$SNAP_COMMON/config/<app>.conf" <<EOF
port=$port
log_level=$log_level
workers=$workers
EOF
```

**Pattern for YAML config files:**
```bash
port=$(snapctl get port); port="${port:-8080}"
log_level=$(snapctl get log-level); log_level="${log_level:-info}"

mkdir -p "$SNAP_COMMON/config"
cat > "$SNAP_COMMON/config/<app>.yaml" <<EOF
server:
  port: $port
logging:
  level: $log_level
EOF
```

**Pattern for JSON config files:**
```bash
port=$(snapctl get port); port="${port:-8080}"
log_level=$(snapctl get log-level); log_level="${log_level:-info}"

mkdir -p "$SNAP_COMMON/config"
cat > "$SNAP_COMMON/config/<app>.json" <<EOF
{
  "port": $port,
  "log_level": "$log_level"
}
EOF
```

> **TOML note:** TOML has no portable shell generation tool available in the
> snap base. Use a Python one-liner inside the hook:
> ```bash
> python3 -c "
> import sys
> port = int('$port')
> print(f'[server]\nport = {port}\n')
> " > "\$SNAP_COMMON/config/<app>.toml"
> ```

### 4.3 Restart the service (daemon snaps only)

```bash
# Only if this is a daemon snap — skip for run-to-completion apps
snapctl restart <snap-name>.<app-name>
```

Check whether the snap is a daemon (`--do-not-daemonize` was NOT passed to
`docker-to-snap`) before adding this line. For non-daemon snaps, skip it.

### 4.4 Template: `snap/hooks/configure`

See `snap-packager/assets/configure-hook-template.sh` for a full template.

---

## 5. Wire the config file into the app invocation

The application must be told to read the config file from `$SNAP_COMMON`.

### 5.1 Via CLI flag (preferred when available)

If the application accepts a `--config` flag or equivalent, add it to the
`command:` in `snapcraft.yaml` via a wrapper script. Inspect the rootfs to
find the entrypoint and its flags:

```bash
# Find the entrypoint binary
python3 -c "import json; c=json.load(open('config.json')); print(c['process']['args'])"

# Check for --config or similar flags
rootfs/usr/bin/<app> --help 2>&1 | grep -iE 'config|conf' | head -20
```

In the wrapper (`library_wrapper.sh` or a custom wrapper):
```bash
exec "$SNAP/usr/bin/<app>" --config "$SNAP_COMMON/config/<app>.conf" "$@"
```

Or via `APP_ARGS` in `snapcraft.yaml`:
```yaml
environment:
  APP_ARGS: --config $SNAP_COMMON/config/<app>.conf
```

### 5.2 Via environment variable

If the application reads its config path from an env var:
```yaml
environment:
  <APP>_CONFIG_FILE: $SNAP_COMMON/config/<app>.conf
  # or
  <APP>_CONFIG_PATH: $SNAP_COMMON/config
```

### 5.3 Via layout (config file at expected path)

If the application always reads from a hardcoded path (e.g. `/etc/<app>/<app>.conf`)
and offers no way to redirect it:

1. Add a layout in `snapcraft.yaml`:
   ```yaml
   layout:
     /etc/<app>:
       bind: $SNAP_COMMON/etc/<app>
   ```
2. Create the directory in the install hook:
   ```bash
   mkdir -p "$SNAP_COMMON/etc/<app>"
   cp "$SNAP/etc/<app>/<app>.conf" "$SNAP_COMMON/etc/<app>/<app>.conf"
   ```
3. The configure hook writes to `$SNAP_COMMON/etc/<app>/<app>.conf`.

The layout binds the hardcoded path to the writable `$SNAP_COMMON` location
at runtime, so the application reads the operator-configured file transparently.

> Do NOT use `$SNAP/etc/<app>` as the layout target for the config file — `$SNAP`
> is read-only and the configure hook cannot write there.

### 5.4 Override-build step to set default config file path

If the application reads a config path baked into a config file bundled in the
image (e.g. a `.env` file with `CONFIG_PATH=/etc/app/app.conf`), add an
`override-build` step that rewrites the path to `$SNAP_COMMON`:

```yaml
override-build: |
  craftctl default
  sed -i 's|CONFIG_PATH=.*|CONFIG_PATH=$SNAP_COMMON/config/<app>.conf|g' \
      "$CRAFT_PART_INSTALL/etc/<app>/.env"
```

---

## 6. snapcraft.yaml hooks stanza

Add a `hooks:` section to `snapcraft.yaml` to declare that hooks are present.
The `network-control` plug is typically required (docker-to-snap generated hooks
write `/etc/hosts`). Add `network-control` if not already present in the hooks
plugs list.

```yaml
hooks:
  install:
    plugs:
      - network-control
  configure:
    plugs:
      - network-control
```

> If the snap already has a `hooks:` section (generated by `docker-to-snap`),
> merge the new `install:` and `configure:` entries into it rather than
> replacing it.

---

## 7. Decision tree: env-var vs config-file

```
Does the application accept a config file?
├── Yes → Use config-file approach (§3–§5)
│         Does it accept a --config flag or env var to set the path?
│         ├── Yes (flag)  → Use APP_ARGS or wrapper CLI flag (§5.1)
│         ├── Yes (env)   → Use environment: in snapcraft.yaml (§5.2)
│         └── No (hardcoded path) → Use layout to bind hardcoded path to
│                                    $SNAP_COMMON (§5.3)
└── No  → Use environment variables only
          Add each option to environment: in snapcraft.yaml
          The configure hook writes them to a sourced env file:
            $SNAP_COMMON/config/env
          The wrapper sources that file before exec.
```

### Env-file pattern (no config-file support)

In the configure hook:
```bash
port=$(snapctl get port); port="${port:-8080}"
log_level=$(snapctl get log-level); log_level="${log_level:-info}"

mkdir -p "$SNAP_COMMON/config"
cat > "$SNAP_COMMON/config/env" <<EOF
export APP_PORT=$port
export APP_LOG_LEVEL=$log_level
EOF
```

In the wrapper script (`library_wrapper.sh` or a custom wrapper), add near the top:
```bash
# Source snap-managed configuration
if [ -f "$SNAP_COMMON/config/env" ]; then
    # shellcheck source=/dev/null
    . "$SNAP_COMMON/config/env"
fi
```

---

## 8. Validation patterns

### 8.1 Required vs optional keys

- Treat all exposed snap config keys as **optional** — defaults must always work.
- Never exit non-zero from the configure hook because a key is unset; exit only
  when a value is set but invalid.

### 8.2 Empty string handling

`snapctl get <key>` returns an empty string when the key is not set. Always
check for empty before validating:

```bash
port=$(snapctl get port)
if [ -n "$port" ]; then
    # validate only when set
    ...
fi
```

### 8.3 Numeric range checks in POSIX sh

```bash
if ! [ "$value" -ge "$min" ] 2>/dev/null || ! [ "$value" -le "$max" ] 2>/dev/null; then
    echo "ERROR: '$key' must be between $min and $max" >&2
    exit 1
fi
```

### 8.4 Rejecting dangerous characters

For values that will be interpolated into a config file (not passed through a
safe cat here-doc), reject shell metacharacters:

```bash
if echo "$value" | grep -qE '[;&|`$(){}]'; then
    echo "ERROR: '$key' contains disallowed characters" >&2
    exit 1
fi
```

---

## 9. Testing the hooks

After writing and installing the hooks:

```bash
# Inside the LXD test container (snap-test)

# 1. Install the snap in devmode first
snap install --dangerous --devmode <snap>.snap

# 2. Verify install hook ran (check $SNAP_COMMON)
ls -la /var/snap/<snap-name>/common/config/

# 3. Verify default config file was created
cat /var/snap/<snap-name>/common/config/<app>.conf

# 4. Set a valid config value
snap set <snap-name> port=9090

# 5. Verify configure hook wrote the new value
cat /var/snap/<snap-name>/common/config/<app>.conf

# 6. Test validation — set an invalid value (must fail)
snap set <snap-name> port=99999   # should fail with error message
snap set <snap-name> log-level=verbose  # should fail if not in allowed list

# 7. Verify the service restarted (daemon snaps only)
snap services <snap-name>
snap logs <snap-name>.<app-name>
```

---

## 10. Common mistakes and how to avoid them

| Mistake | Consequence | Fix |
|---|---|---|
| Writing config to `$SNAP` | Hook fails — `$SNAP` is read-only | Write to `$SNAP_COMMON` |
| Not guarding default config creation with `[ ! -f ... ]` | Re-install wipes operator config | Always check before writing |
| Calling `snapctl restart` in a non-daemon snap | `snap set` fails: "unknown service" | Only restart in daemon snaps |
| Validation exits non-zero when key is unset | `snap set` on any key fails | Only validate when value is non-empty |
| Config file written to `$SNAP_DATA` | Config lost on snap upgrade | Use `$SNAP_COMMON` for persistent config |
| Layout pointing to `$SNAP/etc/...` for the config file | Application cannot save config | Layout target must be `$SNAP_COMMON/...` |
| Forgetting `chmod +x snap/hooks/configure` | snapd silently ignores hook | Always make hooks executable |
| Missing `hooks:` stanza in snapcraft.yaml | Hooks not packaged | Add `hooks:` with plug declarations |
