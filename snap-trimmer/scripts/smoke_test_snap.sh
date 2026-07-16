#!/usr/bin/env bash
#
# smoke_test_snap.sh — install a trimmed .snap in a throwaway LXD container and
# confirm it still launches (Phase 4 smoke test).
#
# WHY LXD and not `sudo snap install` on the host:
#   * `sudo` needs a password → fails in non-interactive/automated runs.
#   * installing on the host pollutes the developer's snapd and can clash with an
#     already-installed copy of the same snap.
# A disposable container sidesteps both and is always torn down on exit.
#
# UNLIKE the snap-validator skill, this does NOT hard-stop on classic confinement —
# trimming a classic snap (e.g. helix) is valid. It reads confinement from the
# snap's own meta/snap.yaml and installs with `--classic` when needed.
#
# Usage:
#   smoke_test_snap.sh <file.snap> [options]
#
# Options:
#   --cmd "<cmdline>"   A command to run inside the container to prove the app works.
#                       Repeatable. Default: derive "<app> --version" and "<app> --help"
#                       from the snap's apps. Prefix-free names are auto-namespaced
#                       (e.g. "hx --version" becomes "helix.hx --version" if needed).
#   --image <img>       LXD image (default: ubuntu:24.04; falls back to ubuntu:noble).
#   --name <container>  Container name (default: snap-trim-smoke).
#   --keep              Do not delete the container on exit (for debugging).
#
# Exit status: 0 if install + all commands succeed; nonzero otherwise. When lxc is
# unavailable it prints exact manual instructions and exits 3 (not a test failure).
#
# All diagnostics -> stderr; the pass/fail report -> stdout.

set -u

err()  { printf '%s\n' "$*" >&2; }
die()  { err "ERROR: $*"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

SNAP=""; IMAGE="ubuntu:24.04"; NAME="snap-trim-smoke"; KEEP=0
declare -a CMDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cmd)   CMDS+=("${2:-}"); shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --name)  NAME="${2:-}"; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*)      die "unknown option: $1" ;;
    *)       [ -z "$SNAP" ] && SNAP="$1" || die "unexpected arg: $1"; shift ;;
  esac
done

[ -n "$SNAP" ] || die "usage: smoke_test_snap.sh <file.snap> [options]"
[ -f "$SNAP" ] || die "not a file: $SNAP"
SNAP="$(readlink -f "$SNAP")"
SNAP_BN="$(basename "$SNAP")"

# ---- read name + confinement from the snap itself --------------------------
CONF="strict"; SNAP_NAME=""
if have unsquashfs; then
  META="$(unsquashfs -cat "$SNAP" meta/snap.yaml 2>/dev/null || unsquashfs -p 1 -cat "$SNAP" meta/snap.yaml 2>/dev/null)"
  SNAP_NAME="$(printf '%s\n' "$META" | awk '/^name:/{print $2; exit}')"
  c="$(printf '%s\n' "$META" | awk '/^confinement:/{print $2; exit}')"
  [ -n "$c" ] && CONF="$c"
  # derive default commands from apps if none supplied.
  # App names are the 2-space-indented keys under `apps:`; the block ends at the
  # next top-level (column-0) key.
  if [ "${#CMDS[@]}" -eq 0 ]; then
    APPS="$(printf '%s\n' "$META" | awk '
      /^apps:[[:space:]]*$/ {f=1; next}
      f && /^[^[:space:]]/    {f=0}
      f && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {gsub(/[: ]/,""); print}
    ')"
    for app in $APPS; do
      if [ "$app" = "$SNAP_NAME" ]; then cmd="$app"; else cmd="$SNAP_NAME.$app"; fi
      CMDS+=("$cmd --version"); CMDS+=("$cmd --help")
    done
  fi
else
  err ">> unsquashfs unavailable; cannot auto-read confinement/apps. Assuming strict."
fi
[ "${#CMDS[@]}" -eq 0 ] && err ">> No app commands derived; will only verify install succeeds."

INSTALL_FLAGS="--dangerous"
[ "$CONF" = "classic" ] && INSTALL_FLAGS="--dangerous --classic"

err ">> snap:        $SNAP_BN"
err ">> name:        ${SNAP_NAME:-<unknown>}"
err ">> confinement: $CONF  (install flags: $INSTALL_FLAGS)"

# ---- lxc availability: degrade to manual instructions ----------------------
if ! have lxc; then
  cat <<EOF
⚠️  lxc (LXD) is not available — cannot run the containerized smoke test here.

Run this yourself in a clean LXD container (recommended over host install, which
needs sudo and pollutes your snapd):

  lxc launch $IMAGE $NAME -c security.nesting=true
  lxc exec $NAME -- cloud-init status --wait
  lxc file push "$SNAP" $NAME/tmp/$SNAP_BN
  lxc exec $NAME -- snap install $INSTALL_FLAGS /tmp/$SNAP_BN
EOF
  for c in "${CMDS[@]:-}"; do [ -n "$c" ] && echo "  lxc exec $NAME -- $c"; done
  cat <<EOF
  lxc delete --force $NAME

(If you must test on the host instead: sudo snap install $INSTALL_FLAGS "$SNAP")
EOF
  exit 3
fi

# ---- provision, install, run, teardown -------------------------------------
CREATED=0
cleanup() {
  if [ "$CREATED" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
    err ">> Tearing down container $NAME"
    lxc delete --force "$NAME" >/dev/null 2>&1 || err "   (cleanup: could not delete $NAME)"
  elif [ "$KEEP" -eq 1 ]; then
    err ">> --keep set: container $NAME left running (delete with: lxc delete --force $NAME)"
  fi
}
trap cleanup EXIT

# Remove any stale container of the same name first.
lxc info "$NAME" >/dev/null 2>&1 && lxc delete --force "$NAME" >/dev/null 2>&1

err ">> Launching $IMAGE as $NAME ..."
if ! lxc launch "$IMAGE" "$NAME" -c security.nesting=true >/dev/null 2>&1; then
  err "   $IMAGE failed; trying ubuntu:noble"
  lxc launch ubuntu:noble "$NAME" -c security.nesting=true >/dev/null 2>&1 \
    || die "could not launch an LXD container (checked $IMAGE and ubuntu:noble)"
fi
CREATED=1

err ">> Waiting for cloud-init ..."
lxc exec "$NAME" -- cloud-init status --wait >/dev/null 2>&1 || err "   (cloud-init wait returned nonzero; continuing)"

err ">> Pushing and installing the snap ..."
lxc file push "$SNAP" "$NAME/tmp/$SNAP_BN" >/dev/null 2>&1 || die "lxc file push failed"

INSTALL_OUT="$(lxc exec "$NAME" -- snap install $INSTALL_FLAGS "/tmp/$SNAP_BN" 2>&1)"
INSTALL_RC=$?
if [ "$INSTALL_RC" -ne 0 ]; then
  echo "❌ INSTALL FAILED (rc=$INSTALL_RC):"
  printf '%s\n' "$INSTALL_OUT" | sed 's/^/     /'
  echo ""
  echo "If the error mentions missing shared libraries, cross-check the compare_snaps.sh"
  echo "§4 soname regression list — a trim may have removed a still-needed library."
  exit 1
fi
echo "✅ install: $INSTALL_OUT"

# ---- run each command, collect pass/fail -----------------------------------
FAIL=0
if [ "${#CMDS[@]}" -gt 0 ]; then
  echo ""
  echo "Command checks:"
  for c in "${CMDS[@]}"; do
    [ -n "$c" ] || continue
    OUT="$(lxc exec "$NAME" -- sh -c "$c" 2>&1)"; RC=$?
    FIRST="$(printf '%s\n' "$OUT" | head -1)"
    if [ "$RC" -eq 0 ]; then
      printf '  ✅ %-30s -> %s\n' "$c" "$FIRST"
    else
      # --version/--help returning nonzero is common for TUIs; show but only fail
      # hard if the output looks like a loader/library error.
      if printf '%s\n' "$OUT" | grep -qiE 'error while loading shared libraries|symbol lookup error|not found|cannot open shared object'; then
        printf '  ❌ %-30s -> %s\n' "$c" "$FIRST"
        FAIL=1
      else
        printf '  ⚠️  %-30s -> rc=%s: %s\n' "$c" "$RC" "$FIRST"
      fi
    fi
  done
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✅ SMOKE TEST PASSED — snap installs ($CONF) and app commands run with no"
  echo "   missing-library errors."
  exit 0
else
  echo "❌ SMOKE TEST FAILED — a command hit a missing/loader library error. A trim"
  echo "   likely removed a still-needed library; check compare_snaps.sh §4 and revert."
  exit 1
fi
