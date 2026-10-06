#!/bin/bash
# snap/hooks/configure — Template for snaps with snap options (OCI and source builds)
#
# This hook runs every time the operator calls:
#   snap set <snap-name> <key>=<value>
# and once during installation, right after the install hook.
#
# Any snap with snap options MUST ship this hook: snapd rejects every `snap set`
# on a snap without one ("snap has no 'configure' hook").
#
# Two variants:
#   - The hook writes a config file the app reads (OCI options, or source options
#     with source config_file/env_var/cli_flag): use sections 1–5.
#   - The app reads `snapctl get` itself (source options with source "snapctl"):
#     use sections 1, 2 and 5 only; delete sections 3 and 4 — no config file.
#
# Replace all <PLACEHOLDERS> before use.
# Make executable: chmod +x snap/hooks/configure
#
# See references/snap-config-guide.md for the full guide.

set -e

# ─── 1. READ SNAP CONFIG KEYS ─────────────────────────────────────────────────
# Read each exposed option.  snapctl get returns "" when the key is not set.

port=$(snapctl get port)
log_level=$(snapctl get log-level)
# workers=$(snapctl get workers)
# debug=$(snapctl get debug)
# tls_cert_file=$(snapctl get tls.cert-file)
# tls_key_file=$(snapctl get tls.key-file)

# ─── 2. VALIDATE EACH VALUE ───────────────────────────────────────────────────
# Only validate when a value is non-empty — unset keys use application defaults.
# Exit 1 with a descriptive message to cause `snap set` to reject the value.

# -- port: integer 1–65535
if [ -n "$port" ]; then
    if ! echo "$port" | grep -qE '^[0-9]+$' \
       || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "ERROR: 'port' must be an integer between 1 and 65535 (got: '$port')" >&2
        exit 1
    fi
fi

# -- log-level: one of the allowed values
if [ -n "$log_level" ]; then
    case "$log_level" in
        debug|info|warn|warning|error|fatal) ;;   # <-- adjust to your app's levels
        *)
            echo "ERROR: 'log-level' must be one of: debug, info, warn, warning, error, fatal (got: '$log_level')" >&2
            exit 1
            ;;
    esac
fi

# -- debug: boolean true/false  (uncomment if used)
# if [ -n "$debug" ]; then
#     case "$debug" in
#         true|false) ;;
#         *)
#             echo "ERROR: 'debug' must be 'true' or 'false' (got: '$debug')" >&2
#             exit 1
#             ;;
#     esac
# fi

# -- workers: positive integer  (uncomment if used)
# if [ -n "$workers" ]; then
#     if ! echo "$workers" | grep -qE '^[1-9][0-9]*$'; then
#         echo "ERROR: 'workers' must be a positive integer (got: '$workers')" >&2
#         exit 1
#     fi
# fi

# -- tls.cert-file: path that must exist when set  (uncomment if used)
# if [ -n "$tls_cert_file" ] && [ ! -f "$tls_cert_file" ]; then
#     echo "ERROR: 'tls.cert-file' path does not exist: '$tls_cert_file'" >&2
#     exit 1
# fi

# ─── 3. APPLY DEFAULTS FOR UNSET KEYS ────────────────────────────────────────
# (Config-file variant only — delete when the app reads `snapctl get` itself.)
# Fall back to the application's built-in defaults so the generated config file
# always has all keys populated.

port="${port:-8080}"            # <-- replace with application default
log_level="${log_level:-info}"  # <-- replace with application default
# workers="${workers:-4}"
# tls_cert_file="${tls_cert_file:-}"
# tls_key_file="${tls_key_file:-}"

# ─── 4. WRITE CONFIG FILE TO $SNAP_COMMON ─────────────────────────────────────
# (Config-file variant only — delete when the app reads `snapctl get` itself.)
# Choose ONE of the blocks below matching your application's config format.
# Delete the others.

mkdir -p "$SNAP_COMMON/config"

# ── Option A: key=value / INI format ─────────────────────────────────────────
cat > "$SNAP_COMMON/config/<app>.conf" <<EOF
# <App> configuration — managed by snap hooks
# To change settings: snap set <snap-name> <key>=<value>
port=$port
log_level=$log_level
EOF
# workers=$workers

# ── Option B: YAML format ─────────────────────────────────────────────────────
# cat > "$SNAP_COMMON/config/<app>.yaml" <<EOF
# # <App> configuration — managed by snap hooks
# server:
#   port: $port
# logging:
#   level: $log_level
# EOF

# ── Option C: JSON format ─────────────────────────────────────────────────────
# cat > "$SNAP_COMMON/config/<app>.json" <<EOF
# {
#   "port": $port,
#   "log_level": "$log_level"
# }
# EOF

# ── Option D: env-file (no native config-file support) ───────────────────────
# Used when the application reads settings only from environment variables.
# The wrapper script must source this file before exec-ing the binary.
# See references/snap-config-guide.md §7 for the wrapper modification.
#
# cat > "$SNAP_COMMON/config/env" <<EOF
# export APP_PORT=$port
# export APP_LOG_LEVEL=$log_level
# EOF

# ─── 5. RESTART SERVICE (DAEMON SNAPS ONLY) ───────────────────────────────────
# Remove this block for run-to-completion (non-daemon) snaps, and when no changed
# option needs a restart (the daemon re-reads it, or reads it per request).
# If omitted for a daemon that reads options only at startup, new values take
# effect only after a manual restart.
#
# Restart only when the daemon is running: during installation this hook runs
# before services start.
#
# if snapctl services "$SNAP_INSTANCE_NAME.<app-name>" | awk 'NR>1 {print $3}' | grep -qx active; then
#     snapctl restart "$SNAP_INSTANCE_NAME.<app-name>"
# fi
