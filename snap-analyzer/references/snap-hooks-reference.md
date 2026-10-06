# Snap Hooks Reference

Hooks are shell scripts in `snap/hooks/` that snapd calls at specific lifecycle events. Add them only when the app has genuine lifecycle requirements.

All hooks:
- Must be executable (`chmod +x`)
- Must start with `#!/bin/bash` and `set -e`
- Run as root (system snaps) or as the calling user (user snaps)
- Must complete within a reasonable time (default timeout: 10 minutes for most hooks)
- Use `snapctl` to read/write snap options and interact with snapd

---

## Hook: install

**When to add:** The app needs one-time setup on first install — creating directories, writing initial config, seeding a database, or setting default option values.

**When NOT to add:** The app handles its own first-run setup internally (creates its own dirs/config on startup). Most well-written apps don't need this hook.

**Daemon config seeding pattern:** For server/daemon apps whose upstream default config hardcodes absolute paths incompatible with strict confinement, always seed a corrected config into `$SNAP_COMMON` (or `$SNAP_DATA`) from the `install` hook rather than copying the upstream default verbatim. The daemon wrapper should point at `$SNAP_COMMON` so the user can freely edit the config after install without the snap overwriting it on refresh.

```bash
#!/bin/bash
set -e

# Seed corrected config on first install only — never overwrite user edits.
# Upstream default writes its pid file under the read-only install prefix;
# point it at $SNAP_COMMON. Keep `listen 80`: a root daemon with network-bind
# can bind it.
if [ ! -f "$SNAP_COMMON/conf/nginx.conf" ]; then
    mkdir -p "$SNAP_COMMON/conf" "$SNAP_COMMON/logs" "$SNAP_COMMON/html"
    sed "s|^#\{0,1\}pid .*|pid $SNAP_COMMON/logs/nginx.pid;|" \
        "$SNAP/usr/local/nginx/conf/nginx.conf" \
        > "$SNAP_COMMON/conf/nginx.conf"
    cp -r "$SNAP/usr/local/nginx/html/." "$SNAP_COMMON/html/"
fi
```

```bash
#!/bin/bash
set -e

# Create directories the app expects
mkdir -p $SNAP_DATA/config
mkdir -p $SNAP_COMMON/logs

# Write initial config if it doesn't exist
if [ ! -f "$SNAP_DATA/config/settings.yaml" ]; then
    cp $SNAP/etc/my-app/settings.yaml.default $SNAP_DATA/config/settings.yaml
fi

# Seed default snap options, only when unset so a reinstall keeps user choices.
# Any snap option means the snap also needs a configure hook.
[ -n "$(snapctl get port)" ] || snapctl set port=8080
[ -n "$(snapctl get log-level)" ] || snapctl set log-level=info
```

---

## Hook: configure

**When to add:** The snap has **any** snap option — a key users change with
`snap set my-app key=value`, or a key a hook or the app reads with `snapctl get`.

**Required, not optional:** snapd rejects every `snap set` on a snap that has no
`configure` hook (`snap "my-app" has no "configure" hook`). This holds even when the app
reads the option itself and the hook has nothing to write.

**When NOT to add:** The snap has no snap options.

Rules for every `configure` hook:
- Validate a value only when it is non-empty, so an unset key never makes `snap set` fail.
  snapd also runs `configure` during installation, right after the `install` hook.
- Restart a daemon only when it is running. During installation services haven't started
  yet, so guard the restart with `snapctl services`.
- Restart only for options a running daemon reads at startup.

### Pattern A: the hook writes a config file the app reads

```bash
#!/bin/bash
set -e

PORT=$(snapctl get port)
LOG_LEVEL=$(snapctl get log-level)

# Validate (only when set)
if [ -n "$PORT" ] && ! { [ "$PORT" -ge 1 ] 2>/dev/null && [ "$PORT" -le 65535 ]; }; then
    echo "port must be an integer between 1 and 65535, got '$PORT'" >&2
    exit 1
fi

# Write config file the app reads
cat > $SNAP_COMMON/settings.yaml <<EOF
port: ${PORT:-8080}
log_level: ${LOG_LEVEL:-info}
EOF

# Restart the daemon to pick up the new config, only if it is running
if snapctl services "$SNAP_INSTANCE_NAME.my-daemon" | awk 'NR>1 {print $3}' | grep -qx active; then
    snapctl restart "$SNAP_INSTANCE_NAME.my-daemon"
fi
```

### Pattern B: the app reads `snapctl get` itself

When the app or its wrapper calls `snapctl get` directly, the hook writes no config file.
It must still exist so `snap set` succeeds, and it validates and restarts:

```bash
#!/bin/bash
set -e

DEBUG=$(snapctl get debug)
LOG_LEVEL=$(snapctl get log.level)

case "$DEBUG" in
    ""|true|false) ;;
    *) echo "debug must be 'true' or 'false', got '$DEBUG'" >&2; exit 1 ;;
esac
case "$LOG_LEVEL" in
    ""|info|debug) ;;
    *) echo "log.level must be one of: info, debug; got '$LOG_LEVEL'" >&2; exit 1 ;;
esac

# The daemon reads these options only at startup: restart it if it is running
if snapctl services "$SNAP_INSTANCE_NAME.my-daemon" | awk 'NR>1 {print $3}' | grep -qx active; then
    snapctl restart "$SNAP_INSTANCE_NAME.my-daemon"
fi
```

---

## Hook: remove

**When to add:** The app needs to clean up persistent system state on uninstall (e.g., remove a system user it created, revoke certificates, clean up `/etc` via layout).

**When NOT to add:** Snapd automatically removes `$SNAP_DATA` and `$SNAP_COMMON` on removal. Most apps don't need this.

```bash
#!/bin/bash
set -e

# Remove a system user created during install
if id "my-app" &>/dev/null; then
    userdel my-app 2>/dev/null || true
fi
```

---

## Hook: connect-plug-\<plug-name\>

**When to add:** The app needs to take action when a specific interface is connected — e.g., enumerate serial ports after `serial-port` is connected, or reconfigure after `network-manager` is granted.

**Hook filename:** `connect-plug-serial-port`, `connect-plug-camera`, etc. (replace hyphens but keep the `connect-plug-` prefix).

```bash
#!/bin/bash
# snap/hooks/connect-plug-serial-port
set -e

# Detect newly connected serial devices
for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    echo "Serial device connected: $dev" >> $SNAP_DATA/serial-devices.log
done
```

---

## Hook: disconnect-plug-\<plug-name\>

**When to add:** The app needs to handle an interface being revoked — e.g., gracefully closing open device handles, saving state, or notifying users.

```bash
#!/bin/bash
# snap/hooks/disconnect-plug-serial-port
set -e

# Signal the app to close serial connections
snapctl stop my-app.my-daemon 2>/dev/null || true
```

---

## Hook: pre-refresh

**When to add:** The app needs to prepare for an update — saving state, flushing in-flight operations, or gracefully stopping components before the snap binary is replaced.

```bash
#!/bin/bash
set -e

# Export database before update
$SNAP/bin/my-app db export $SNAP_COMMON/pre-refresh-backup.db

# Stop the service (snapd will restart it after refresh)
snapctl stop my-app.my-daemon 2>/dev/null || true
```

---

## Hook: post-refresh

**When to add:** The app needs to run migration steps after an update — applying schema migrations, converting config formats, or rebuilding indexes.

```bash
#!/bin/bash
set -e

# Run database migrations
$SNAP/bin/my-app db migrate $SNAP_DATA/myapp.db

# Remove stale pre-refresh backup
rm -f $SNAP_COMMON/pre-refresh-backup.db
```

---

## snapctl Reference

`snapctl` is the CLI for hooks to interact with snapd:

```bash
# Read a snap option
snapctl get port                    # → 8080
snapctl get -d .                    # → all options as JSON

# Write a snap option
snapctl set port=9090
snapctl set log-level=debug

# Service management from within a hook
snapctl services my-app.my-daemon   # → Service / Startup / Current (active|inactive)
snapctl start my-app.my-daemon
snapctl stop my-app.my-daemon
snapctl restart my-app.my-daemon

# Read snap info
snapctl get --slot my-slot key      # read from a connected slot
```

---

## Declaring Hooks in snapcraft.yaml

Hooks are auto-discovered from `snap/hooks/` — you do not need to declare them in `snapcraft.yaml` unless you need to assign plugs to the hook itself (e.g., the `configure` hook needs `network` to call an external service).

```yaml
hooks:
  configure:
    plugs:
      - network    # only needed if the configure hook makes network calls
  install:
    plugs: []      # no extra interfaces needed
```

---

## File Permissions

Git does not store execute bits reliably across platforms. Document in `SNAP_PACKAGING.md`:

```bash
chmod +x snap/hooks/*
```

Or use a `snapcraft.yaml` `override-prime` step to set permissions:

```yaml
parts:
  hooks:
    plugin: nil
    source: snap/hooks
    override-prime: |
      craftctl default
      chmod +x $CRAFT_PRIME/snap/hooks/*
```
