#!/usr/bin/env bash
#
# analyze_snap.sh — unpack a .snap and print a categorized removal-candidate report.
#
# Read-only, needs no root: uses `unsquashfs` to list and extract into a temp dir.
# NEVER edits the .snap. Its output feeds the trimming plan (Phase 1/2 of SKILL.md).
#
# Usage:
#   analyze_snap.sh <file.snap> [options]
#
# Options:
#   --lint-file <path>     Save/parse a `snapcraft lint <snap>` capture for category A.
#   --base <name>          Base snap name (e.g. core24) for category B dedupe check.
#   --content-snap <name>  Extension/content snap (e.g. gnome-46-2404) for category C.
#                          May be given multiple times.
#   --workdir <dir>        Where to unpack (default: mktemp under /tmp). Kept on exit
#                          so later steps can inspect it; path is printed at the end.
#   --keep / --no-keep     Keep (default) or delete the unpacked tree on exit.
#
# Categories reported (see SKILL.md §Phase 1):
#   A  lint-flagged unused libraries (with dlopen suspicion filtering)
#   B  files duplicated in the base snap
#   C  files duplicated in a content/extension snap
#   D  internal duplicate libraries (same basename shipped twice)
#   E  classic cruft (man/doc/include/static libs/pkgconfig/cmake/locale/…)
#
# All diagnostics go to stderr; the report goes to stdout.

set -u

err()  { printf '%s\n' "$*" >&2; }
die()  { err "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- args ------------------------------------------------------------------
SNAP=""
LINT_FILE=""
BASE=""
CONTENT_SNAPS=()
WORKDIR=""
KEEP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --lint-file)    LINT_FILE="${2:-}"; shift 2 ;;
    --base)         BASE="${2:-}"; shift 2 ;;
    --content-snap) CONTENT_SNAPS+=("${2:-}"); shift 2 ;;
    --workdir)      WORKDIR="${2:-}"; shift 2 ;;
    --keep)         KEEP=1; shift ;;
    --no-keep)      KEEP=0; shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)              [ -z "$SNAP" ] && SNAP="$1" || die "unexpected arg: $1"; shift ;;
  esac
done

[ -n "$SNAP" ]  || die "no .snap file given. Usage: analyze_snap.sh <file.snap> [options]"
[ -f "$SNAP" ]  || die "not a file: $SNAP"
have unsquashfs || die "unsquashfs not found. Install with: sudo apt install squashfs-tools"

SNAP="$(readlink -f "$SNAP")"

# ---- unpack ----------------------------------------------------------------
if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d /tmp/snap-trim.XXXXXX)" || die "mktemp failed"
fi
ROOT="$WORKDIR/squashfs-root"
rm -rf "$ROOT"
err ">> Unpacking $SNAP into $ROOT ..."
if ! unsquashfs -f -d "$ROOT" "$SNAP" >/dev/null 2>&1; then
  die "unsquashfs failed to extract $SNAP"
fi

cleanup() { [ "$KEEP" -eq 0 ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Detect base + extensions from the packed snap.yaml if not supplied.
SNAP_YAML="$ROOT/meta/snap.yaml"
if [ -z "$BASE" ] && [ -f "$SNAP_YAML" ]; then
  BASE="$(awk '/^base:/{print $2; exit}' "$SNAP_YAML")"
fi

# Architecture triplet (best effort) for pretty-printing paths.
TRIPLET="$(ls -d "$ROOT"/usr/lib/*-linux-gnu 2>/dev/null | head -1 | xargs -r basename)"

section() { printf '\n============================================================\n%s\n============================================================\n' "$*"; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# ---- baseline --------------------------------------------------------------
section "BASELINE"
COMPRESSED_BYTES="$(stat -c %s "$SNAP" 2>/dev/null || echo 0)"
UNCOMP_BYTES="$(du -sb "$ROOT" 2>/dev/null | cut -f1)"
printf 'snap file            : %s\n' "$SNAP"
printf 'compressed size      : %s (%s bytes)\n' "$(human "$COMPRESSED_BYTES")" "$COMPRESSED_BYTES"
printf 'uncompressed (prime) : %s (%s bytes)\n' "$(human "$UNCOMP_BYTES")" "$UNCOMP_BYTES"
printf 'base                 : %s\n' "${BASE:-<unknown>}"
printf 'arch triplet         : %s\n' "${TRIPLET:-<unknown>}"

# Save a full file listing next to the workdir for later diffing.
LISTING="$WORKDIR/filelist.txt"
( cd "$ROOT" && find . -type f -o -type l | sort ) > "$LISTING"
printf 'file listing saved   : %s (%s entries)\n' "$LISTING" "$(wc -l < "$LISTING")"

section "TOP 30 LARGEST FILES"
find "$ROOT" -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -30 \
  | while IFS=$'\t' read -r sz path; do printf '%10s  %s\n' "$(human "$sz")" "${path#$ROOT/}"; done

section "TOP 15 LARGEST DIRECTORIES"
du -h "$ROOT" 2>/dev/null | sort -rh | head -16 \
  | while read -r sz path; do [ "$path" = "$ROOT" ] && continue; printf '%10s  %s\n' "$sz" "${path#$ROOT/}"; done

# helper: total bytes of a newline-delimited list of paths (relative to ROOT)
sum_paths() {
  local total=0 sz p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    sz="$(du -sb "$ROOT/$p" 2>/dev/null | cut -f1)"
    total=$(( total + ${sz:-0} ))
  done
  echo "$total"
}

# ---- Category A: lint-flagged unused libraries -----------------------------
# dlopen suspicion list — libraries loaded at runtime are invisible to the
# library linter's static DT_NEEDED analysis and get falsely flagged. KEEP these.
DLOPEN_SUSPECT_RE='(/dri/|/gstreamer-1\.0/|/qt5/plugins/|/qt6/plugins/|/gtk-[0-9.]*/modules/|/gtk-[0-9.]*/immodules/|/alsa-lib/|/pulseaudio/|/gio/modules/|/pipewire|/spa-|/vdpau/|/dpau/|libnss|libpam|/samba/|/krb5/|_va|libva|libvdpau|/plugins/|/pkcs11/|/engines-|/gconv/)'

section "CATEGORY A — LINT-FLAGGED UNUSED LIBRARIES"
if [ -n "$LINT_FILE" ] && [ -f "$LINT_FILE" ]; then
  # Match lines like:  - library: <soname>: unused library 'usr/lib/.../libfoo.so.1'
  A_ALL="$(grep -oE "unused library '[^']+'" "$LINT_FILE" | sed -E "s/unused library '([^']+)'/\1/" | sort -u)"
  if [ -z "$A_ALL" ]; then
    err "No 'unused library' lines found in $LINT_FILE."
    echo "(none found in lint output)"
  else
    echo "# Strong removal candidates (not on dlopen suspicion list):"
    echo "$A_ALL" | grep -Ev "$DLOPEN_SUSPECT_RE" | while read -r p; do
      [ -z "$p" ] && continue
      sz="$(stat -c %s "$ROOT/$p" 2>/dev/null || echo 0)"
      printf '  [candidate] %10s  %s\n' "$(human "$sz")" "$p"
    done
    echo ""
    echo "# SUSPICIOUS — likely dlopen'd, KEEP unless proven unused:"
    echo "$A_ALL" | grep -E "$DLOPEN_SUSPECT_RE" | while read -r p; do
      [ -z "$p" ] && continue
      printf '  [KEEP?]     %s\n' "$p"
    done
    echo ""
    echo "# Next: trace each candidate to its stage-packages entry (dpkg -S on a"
    echo "#       matching Ubuntu container, or grep the package name). Drop the"
    echo "#       whole package if entirely unused; else add a prime: exclusion."
  fi
else
  echo "(no --lint-file given; run 'snapcraft lint $SNAP' and pass --lint-file, or"
  echo " rely on the Phase 4 soname-resolution static check instead)"
fi

# ---- Category E: classic cruft ---------------------------------------------
# (Done before B/C so we can report byte totals cleanly.)
section "CATEGORY E — CLASSIC CRUFT (usually safe)"
declare -A CRUFT_DESC=(
  [man]="usr/share/man"
  [info]="usr/share/info"
  [lintian]="usr/share/lintian"
  [bug]="usr/share/bug"
  [doc]="usr/share/doc (EXCEPT files named 'copyright')"
  [include]="usr/include"
  [pkgconfig]="usr/lib/**/pkgconfig"
  [cmake]="usr/lib/**/cmake"
  [staticlibs]="*.a / *.la static libraries"
  [pycache]="__pycache__ dirs"
  [themes]="usr/share/themes"
)
report_cruft() {
  local label="$1"; shift
  local files; files="$(cd "$ROOT" && eval "$@" 2>/dev/null | sort)"
  local n; n="$(printf '%s\n' "$files" | grep -c . )"
  local bytes; bytes="$(printf '%s\n' "$files" | sum_paths)"
  printf '  %-12s %6s files  %10s   (%s)\n' "$label" "$n" "$(human "$bytes")" "${CRUFT_DESC[$label]:-}"
}
report_cruft man        "find usr/share/man -type f 2>/dev/null"
report_cruft info       "find usr/share/info -type f 2>/dev/null"
report_cruft lintian    "find usr/share/lintian -type f 2>/dev/null"
report_cruft bug        "find usr/share/bug -type f 2>/dev/null"
report_cruft doc        "find usr/share/doc -type f -not -name copyright 2>/dev/null"
report_cruft include    "find usr/include -type f 2>/dev/null"
report_cruft pkgconfig  "find usr/lib -type d -name pkgconfig 2>/dev/null"
report_cruft cmake      "find usr/lib -type d -name cmake 2>/dev/null"
report_cruft staticlibs "find . \( -name '*.a' -o -name '*.la' \) -type f 2>/dev/null"
report_cruft pycache    "find . -type d -name __pycache__ 2>/dev/null"
report_cruft themes     "find usr/share/themes -type f 2>/dev/null"

# license safety: count what we would PRESERVE, loudly — ALL license files anywhere in
# the tree (not just usr/share/doc/copyright: vendored/source trees carry their own).
LICENSE_N="$( (cd "$ROOT" && find . -type f \
  \( -iname 'copyright' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' \
     -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' -o -iname 'UNLICENSE*' \) 2>/dev/null) | wc -l )"
printf '\n  >> PRESERVE: %s license files (copyright/LICENSE/COPYING/NOTICE/… anywhere) — NEVER delete.\n' "$LICENSE_N"
printf '     When removing a whole directory tree, relocate its license files first (see §5.6).\n'

echo ""
echo "# ASK THE USER before removing (product decisions, not cruft):"
LOCALE_BYTES="$( (cd "$ROOT" && find usr/share/locale -type f 2>/dev/null) | sum_paths )"
printf '  locale        %10s   usr/share/locale (removing = dropping translations)\n' "$(human "$LOCALE_BYTES")"

# ---- Category D: internal duplicate libraries ------------------------------
section "CATEGORY D — INTERNAL DUPLICATE LIBRARIES (same basename, 2+ copies)"
( cd "$ROOT" && find . -type f -name '*.so*' -printf '%f\t%s\t%p\n' 2>/dev/null ) \
  | sort | awk -F'\t' '
      { name=$1; count[name]++; lines[name]=lines[name] sprintf("      %10d  %s\n",$2,$3) }
      END { for (n in count) if (count[n] > 1) printf "  %s  (%d copies)\n%s", n, count[n], lines[n] }
  ' | sed "s#\./#/#g" | head -80
echo "  (empty above = no internal duplicate .so files detected)"

# ---- Category G: build scratch over-copied into prime ----------------------
# Heuristic: directories containing source-checkout / build-scratch signatures that
# a runtime almost never needs. Often the single biggest win. Reported as suspects to
# investigate — confirm each is build-only before removing (fix in override-build, §5.7).
section "CATEGORY G — BUILD SCRATCH / OVER-COPIED SOURCES (investigate; often biggest win)"
# 1. embedded VCS dirs (never needed at runtime)
GIT_BYTES="$( (cd "$ROOT" && find . -type d -name '.git' 2>/dev/null | sed 's#$#/#' ) | sum_paths )"
GIT_N="$( (cd "$ROOT" && find . -type d -name '.git' 2>/dev/null) | wc -l )"
printf '  .git dirs            %6s dirs  %10s   (VCS checkouts — never runtime)\n' "$GIT_N" "$(human "$GIT_BYTES")"
# 2. source/intermediate files by extension
for pat in '*.c' '*.h' '*.cc' '*.cpp' '*.rs' '*.go' '*.o' '*.rlib'; do
  files="$( (cd "$ROOT" && find . -type f -name "$pat" 2>/dev/null) )"
  n="$(printf '%s\n' "$files" | grep -c .)"
  [ "$n" -eq 0 ] && continue
  bytes="$(printf '%s\n' "$files" | sum_paths)"
  printf '  %-20s %6s files  %10s\n' "$pat" "$n" "$(human "$bytes")"
done
# 3. directories whose name screams scratch (sources/, test(s)/, examples/, fixtures/)
echo "  -- suspicious directories (name suggests build/test scratch) --"
( cd "$ROOT" && find . -type d \( -name 'sources' -o -name 'test' -o -name 'tests' \
    -o -name 'examples' -o -name 'fixtures' -o -name 'testdata' \) 2>/dev/null ) \
  | while IFS= read -r d; do
      d="${d#./}"; [ -z "$d" ] && continue
      # skip meta/snap (safety rule 4) — never propose these
      case "$d" in meta/*|snap/*|meta|snap) continue;; esac
      bytes="$(du -sb "$ROOT/$d" 2>/dev/null | cut -f1)"
      printf '    %10s  %s\n' "$(human "${bytes:-0}")" "$d"
    done | sort -rh | head -20
echo "  (Confirm each is build-only — used by a build/dev subcommand, not dlopen'd/read at"
echo "   runtime — before removing. Fix by tightening the part's override-build, §5.7.)"

# ---- Category B/C: dedupe against base / content snaps ---------------------
dedupe_against() {
  local label="$1" snapname="$2"
  local mount="/snap/$snapname/current"
  section "$label — duplicates vs $snapname"
  if [ ! -d "$mount" ]; then
    echo "  $mount not present locally — cannot compare now."
    echo "  This becomes a REBUILD-TIME cleanup (see cleanup-patterns.md §5.3):"
    echo "    add '$snapname' to the cleanup part's build-snaps and rm files that"
    echo "    exist under /snap/$snapname/current from \$CRAFT_PRIME."
    return
  fi
  local dupes bytes n
  # Never propose removing snap-specific metadata or extension-injected files
  # (meta/**, snap/**) even if a same-named file happens to exist in the base.
  dupes="$( ( cd "$ROOT" && find . -type f -o -type l ) | sed 's#^\./##' \
            | grep -Ev '^(meta|snap)/' \
            | while IFS= read -r rel; do [ -e "$mount/$rel" ] && echo "$rel"; done )"
  n="$(printf '%s\n' "$dupes" | grep -c .)"
  bytes="$(printf '%s\n' "$dupes" | sum_paths)"
  printf '  %s duplicated files, %s reclaimable\n' "$n" "$(human "$bytes")"
  printf '%s\n' "$dupes" | head -40 | sed 's/^/    /'
  [ "$n" -gt 40 ] && echo "    ... ($((n-40)) more)"
}

if [ -n "$BASE" ]; then
  dedupe_against "CATEGORY B" "$BASE"
else
  section "CATEGORY B — duplicates vs base snap"
  echo "  base unknown; pass --base <core2x> to check."
fi

if [ "${#CONTENT_SNAPS[@]}" -gt 0 ]; then
  for cs in "${CONTENT_SNAPS[@]}"; do
    dedupe_against "CATEGORY C" "$cs"
  done
else
  section "CATEGORY C — duplicates vs content/extension snap"
  echo "  No --content-snap given. If the yaml uses an extension (gnome, kde-neon),"
  echo "  find its runtime content snap via 'snapcraft expand-extensions' and pass"
  echo "  --content-snap <name> (e.g. gnome-46-2404). This is usually the biggest win."
fi

# ---- footer ----------------------------------------------------------------
section "SUMMARY"
printf 'Unpacked tree kept at : %s\n' "$ROOT"
printf 'File listing          : %s\n' "$LISTING"
echo "Next: build the Phase 2 plan table (category, paths, est. saving, confidence,"
echo "      yaml mechanism) and confirm with the user before editing snapcraft.yaml."
[ "$KEEP" -eq 0 ] && err ">> --no-keep set: removing $WORKDIR on exit."
