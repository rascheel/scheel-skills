#!/usr/bin/env bash
#
# compare_snaps.sh — before/after diff for a trimmed snap (Phase 4 verification).
#
# Read-only, needs no root. Reports:
#   1. size delta        — compressed (.snap) and uncompressed (prime)
#   2. file-list diff    — what disappeared (confirm nothing unexpected) / appeared
#   3. lint diff         — re-run `snapcraft lint` on both and diff warnings (optional)
#   4. dependency check  — every ELF's DT_NEEDED soname must resolve within
#                          {snap, base snap, content snaps}. Compares OLD vs NEW
#                          and flags only REGRESSIONS (resolvable before, broken
#                          after) => a removal went too far; REVERT it. Sonames
#                          unresolved in both are pre-existing, not the trim's fault.
#
# Usage:
#   compare_snaps.sh <old.snap> <new.snap> [options]
#
# Options:
#   --base <name>          Base snap (e.g. core24) whose libs count as "provided".
#   --content-snap <name>  Content/extension snap providing libs. Repeatable.
#   --old-lint <path>      Pre-saved `snapcraft lint <old>` capture.
#   --new-lint <path>      Pre-saved `snapcraft lint <new>` capture.
#   --run-lint             Attempt to run `snapcraft lint` on both here.
#   --workdir <dir>        Where to unpack (default: mktemp under /tmp).
#
# All diagnostics -> stderr; the report -> stdout. Exit code is nonzero only on
# usage/setup errors, NOT on findings (findings are for the agent+user to judge).

set -u

err()  { printf '%s\n' "$*" >&2; }
die()  { err "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

OLD=""; NEW=""; BASE=""; CONTENT_SNAPS=()
OLD_LINT=""; NEW_LINT=""; RUN_LINT=0; WORKDIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)         BASE="${2:-}"; shift 2 ;;
    --content-snap) CONTENT_SNAPS+=("${2:-}"); shift 2 ;;
    --old-lint)     OLD_LINT="${2:-}"; shift 2 ;;
    --new-lint)     NEW_LINT="${2:-}"; shift 2 ;;
    --run-lint)     RUN_LINT=1; shift ;;
    --workdir)      WORKDIR="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)              if [ -z "$OLD" ]; then OLD="$1"; elif [ -z "$NEW" ]; then NEW="$1"; else die "unexpected arg: $1"; fi; shift ;;
  esac
done

[ -n "$OLD" ] && [ -n "$NEW" ] || die "usage: compare_snaps.sh <old.snap> <new.snap> [options]"
[ -f "$OLD" ] || die "not a file: $OLD"
[ -f "$NEW" ] || die "not a file: $NEW"
have unsquashfs || die "unsquashfs not found. Install: sudo apt install squashfs-tools"

OLD="$(readlink -f "$OLD")"; NEW="$(readlink -f "$NEW")"
[ -z "$WORKDIR" ] && WORKDIR="$(mktemp -d /tmp/snap-cmp.XXXXXX)"
OLD_ROOT="$WORKDIR/old"; NEW_ROOT="$WORKDIR/new"
trap 'rm -rf "$WORKDIR"' EXIT

err ">> Unpacking old -> $OLD_ROOT"
unsquashfs -f -d "$OLD_ROOT" "$OLD" >/dev/null 2>&1 || die "failed to unpack $OLD"
err ">> Unpacking new -> $NEW_ROOT"
unsquashfs -f -d "$NEW_ROOT" "$NEW" >/dev/null 2>&1 || die "failed to unpack $NEW"

section(){ printf '\n============================================================\n%s\n============================================================\n' "$*"; }

# ---- 1. size delta ---------------------------------------------------------
section "1. SIZE DELTA"
OC=$(stat -c %s "$OLD"); NC=$(stat -c %s "$NEW")
OU=$(du -sb "$OLD_ROOT" | cut -f1); NU=$(du -sb "$NEW_ROOT" | cut -f1)
pct(){ awk -v o="$1" -v n="$2" 'BEGIN{ if(o==0){print "n/a"} else {printf "%.1f%%", (o-n)*100.0/o} }'; }
printf 'compressed  : %s -> %s  (saved %s, %s)\n' "$(human "$OC")" "$(human "$NC")" "$(human $((OC-NC)))" "$(pct "$OC" "$NC")"
printf 'uncompressed: %s -> %s  (saved %s, %s)\n' "$(human "$OU")" "$(human "$NU")" "$(human $((OU-NU)))" "$(pct "$OU" "$NU")"

# ---- 2. file-list diff -----------------------------------------------------
section "2. FILE-LIST DIFF"
( cd "$OLD_ROOT" && find . -type f -o -type l ) | sed 's#^\./##' | sort > "$WORKDIR/old.list"
( cd "$NEW_ROOT" && find . -type f -o -type l ) | sed 's#^\./##' | sort > "$WORKDIR/new.list"
REMOVED="$(comm -23 "$WORKDIR/old.list" "$WORKDIR/new.list")"
ADDED="$(comm -13 "$WORKDIR/old.list" "$WORKDIR/new.list")"
printf 'removed: %s files   added: %s files\n\n' "$(printf '%s\n' "$REMOVED" | grep -c .)" "$(printf '%s\n' "$ADDED" | grep -c .)"

# Loud safety check: flag any removed license file (anywhere in the tree, not just
# usr/share/doc — vendored deps carry LICENSE/COPYING/NOTICE next to their sources)
# or any snap-metadata file (meta/**, snap/**).
LICENSE_RE='(^|/)(copyright|LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|UNLICENSE)([.-][^/]*)?$'
BAD_REMOVED="$(printf '%s\n' "$REMOVED" | grep -Ei "$LICENSE_RE|^meta/|^snap/" )"
if [ -n "$BAD_REMOVED" ]; then
  echo "  🚨 WARNING — these removals violate the hard safety rules. REVERT:"
  printf '%s\n' "$BAD_REMOVED" | sed 's/^/     /'
  echo ""
fi
echo "-- removed (first 60) --"
printf '%s\n' "$REMOVED" | head -60 | sed 's/^/  - /'
[ "$(printf '%s\n' "$REMOVED" | grep -c .)" -gt 60 ] && echo "  ... (more)"
if [ -n "$ADDED" ]; then
  echo "-- added (unexpected? investigate) --"
  printf '%s\n' "$ADDED" | head -30 | sed 's/^/  + /'
fi

# ---- 3. lint diff ----------------------------------------------------------
section "3. LINT DIFF"
if [ "$RUN_LINT" -eq 1 ] && have snapcraft; then
  OLD_LINT="$WORKDIR/old.lint"; NEW_LINT="$WORKDIR/new.lint"
  err ">> Running snapcraft lint (may fail if host env is broken; that's diagnosable)"
  snapcraft lint "$OLD" >"$OLD_LINT" 2>&1 || err "   old lint returned nonzero (see file)"
  snapcraft lint "$NEW" >"$NEW_LINT" 2>&1 || err "   new lint returned nonzero (see file)"
fi
# Detect the broken-lint-host signature (spec §4).
for f in "$OLD_LINT" "$NEW_LINT"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  if grep -q '__tunable_is_initialized\|symbol lookup error' "$f"; then
    echo "  ⚠️  BROKEN LINT HOST detected in $f:"
    echo "      host glibc vs mounted core2x glibc mismatch — the lint run is INCOMPLETE,"
    echo "      not a verdict on the snap. Remedy: sudo snap refresh core24 && snapd,"
    echo "      or run lint in a clean LXD/multipass. Falling back to the soname check (§4)."
  fi
done
if [ -n "$OLD_LINT" ] && [ -n "$NEW_LINT" ] && [ -f "$OLD_LINT" ] && [ -f "$NEW_LINT" ]; then
  grep -oE "unused library '[^']+'" "$OLD_LINT" 2>/dev/null | sort -u > "$WORKDIR/old.warn" || true
  grep -oE "unused library '[^']+'" "$NEW_LINT" 2>/dev/null | sort -u > "$WORKDIR/new.warn" || true
  echo "resolved (gone from new):"; comm -23 "$WORKDIR/old.warn" "$WORKDIR/new.warn" | sed 's/^/  - /'
  echo "still present:";           comm -12 "$WORKDIR/old.warn" "$WORKDIR/new.warn" | sed 's/^/  · /'
  echo "NEW warnings (investigate):"; comm -13 "$WORKDIR/old.warn" "$WORKDIR/new.warn" | sed 's/^/  + /'
else
  echo "(no lint captures; pass --old-lint/--new-lint or --run-lint. Degrading to §4"
  echo " static soname resolution, which needs no working lint host.)"
fi

# ---- 4. dependency sanity check (soname resolution) ------------------------
# Resolves sonames for BOTH old and new, then flags only REGRESSIONS — sonames
# that were resolvable in the old snap but are unresolved in the new one. A
# soname unresolved in both is pre-existing (shipped in neither snap) and is NOT
# blamed on the trim.
section "4. DEPENDENCY SANITY CHECK (DT_NEEDED soname resolution, old vs new)"
if ! have readelf && ! have objdump; then
  echo "  Neither readelf nor objdump available — install binutils to run this check."
else
  needed_of(){ # print DT_NEEDED sonames of an ELF file
    if have readelf; then readelf -d "$1" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}'
    else objdump -p "$1" 2>/dev/null | awk '/NEEDED/{print $2}'; fi
  }
  soname_of(){ # print the SONAME an ELF advertises (what other libs link against)
    if have readelf; then readelf -d "$1" 2>/dev/null | awk -F'[][]' '/SONAME/{print $2}'
    else objdump -p "$1" 2>/dev/null | awk '/SONAME/{print $2}'; fi
  }

  # Filter obvious glibc/loader sonames that the base always provides even if
  # its tree wasn't mounted for inspection.
  GLIBC_RE='^(ld-linux.*|libc\.so.*|libm\.so.*|libdl\.so.*|libpthread\.so.*|librt\.so.*|libresolv\.so.*|libgcc_s\.so.*|libutil\.so.*)$'

  # Runtime-provided sonames shared by both old and new: base + content snaps.
  RUNTIME_PROVIDED="$WORKDIR/runtime.provided"; : > "$RUNTIME_PROVIDED"
  add_provided_from_mount(){
    local m="/snap/$1/current"
    [ -d "$m" ] || { err ">> $m not mounted; its provided libs are UNKNOWN (may over-report)"; return; }
    err ">> Adding provided sonames from $m"
    while IFS= read -r f; do
      head -c4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
      sn="$(soname_of "$f")"; [ -n "$sn" ] && echo "$sn" >> "$RUNTIME_PROVIDED"
      basename "$f" >> "$RUNTIME_PROVIDED"
    done < <(find "$m" -type f \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null)
  }
  [ -n "$BASE" ] && add_provided_from_mount "$BASE"
  for cs in "${CONTENT_SNAPS[@]:-}"; do [ -n "$cs" ] && add_provided_from_mount "$cs"; done

  # Compute the set of DT_NEEDED sonames that DO NOT resolve within
  # {that snap's own ELFs} ∪ {base+content} ∪ {glibc/loader}. Prints one per line.
  unresolved_for(){
    local root="$1" tag="$2"
    local provided="$WORKDIR/$tag.provided" needed="$WORKDIR/$tag.needed"
    : > "$provided"; : > "$needed"
    err ">> Collecting sonames from the $tag snap ..."
    while IFS= read -r f; do
      head -c4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
      sn="$(soname_of "$f")"; [ -n "$sn" ] && echo "$sn" >> "$provided"
      basename "$f" >> "$provided"   # a file can be referenced by its own basename
      needed_of "$f" >> "$needed"
    done < <(find "$root" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null)
    cat "$RUNTIME_PROVIDED" >> "$provided"
    sort -u "$provided" -o "$provided"
    sort -u "$needed"   -o "$needed"
    comm -23 "$needed" "$provided" | grep -Ev "$GLIBC_RE"
  }

  unresolved_for "$OLD_ROOT" old | sort -u > "$WORKDIR/old.unresolved"
  unresolved_for "$NEW_ROOT" new | sort -u > "$WORKDIR/new.unresolved"

  # Regressions = unresolved in new but NOT unresolved in old.
  REGRESSED="$(comm -13 "$WORKDIR/old.unresolved" "$WORKDIR/new.unresolved")"
  PREEXISTING="$(comm -12 "$WORKDIR/old.unresolved" "$WORKDIR/new.unresolved")"

  if [ -z "$REGRESSED" ]; then
    echo "  ✅ No soname regressions — every DT_NEEDED soname resolvable before the trim"
    echo "     still resolves within {new snap, base, content snaps}."
  else
    echo "  🚨 REGRESSED sonames — resolvable in the OLD snap, unresolved in the NEW one."
    echo "     A trim removed a still-needed library. Re-add the owning file/package:"
    printf '%s\n' "$REGRESSED" | sed 's/^/     - /'
  fi
  if [ -n "$PREEXISTING" ]; then
    echo ""
    echo "  ℹ️  Pre-existing unresolved (unresolved in BOTH — shipped in neither snap, so"
    echo "     NOT caused by the trim; likely provided at runtime or a latent issue):"
    printf '%s\n' "$PREEXISTING" | sed 's/^/     · /'
  fi
  if [ -z "$BASE" ] && [ "${#CONTENT_SNAPS[@]}" -eq 0 ]; then
    echo ""
    echo "  NOTE: no --base/--content-snap given, so provided-set is under-counted."
    echo "  Regression detection still holds (both sides use the same runtime set),"
    echo "  but pass --base <core2x> to shrink the pre-existing list."
  fi
fi

section "DONE"
echo "Interpretation: size should drop with NO unexpected removals, NO new lint"
echo "warnings, and NO soname REGRESSIONS. If any removed file is a license/copyright"
echo "or meta/** file, or a soname regressed, REVERT that change before shipping."
echo "A confinement-aware smoke test (scripts/smoke_test_snap.sh) is the ground truth."
