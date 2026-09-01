---
name: snap-trimmer
description: >
  Trims and shrinks snap packages by editing snapcraft.yaml — never by hand-editing or
  repacking the .snap artifact. Analyzes a prebuilt .snap as ground truth, finds removal
  candidates (lint-flagged unused libraries, duplicates against the base and content/
  extension snaps, internal duplicate libs, classic cruft), proposes a plan, edits the
  yaml, then rebuilds and verifies with size, file-list, lint, and soname-resolution
  checks. WHEN: reduce snap size, shrink a snap, make my snap smaller, remove unused
  libraries from a snap, act on snapcraft lint warnings, unused library warnings, add or
  improve a cleanup part, deduplicate against base or content snaps, dedupe extension libs,
  why is my snap so big, my .snap file is too large, trim snapcraft.yaml.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.1.0"
  summary: "Shrinks snaps by editing snapcraft.yaml — analyzes a prebuilt .snap, plans safe removals, rebuilds, and verifies via soname checks and smoke tests."
  tags:
    - snap
    - snapcraft
    - optimization
    - size
    - canonical
    - linux
---

# Snap Trimming

Shrink a snap by removing unnecessary files **through `snapcraft.yaml` edits only**. The
prebuilt `.snap` is ground truth for *what is actually inside*; the yaml is the only thing
this skill changes. The user (or this skill, if `snapcraft` is available) rebuilds to
produce the trimmed snap.

**A run succeeds when:** (1) measurable size drop, compressed and uncompressed; (2) no
functional regression — app still launches, no newly-missing shared-library deps;
(3) `snapcraft lint` warnings reduced or each remaining one explained/suppressed
deliberately; (4) license/copyright files never deleted.

## 🚨 Hard safety rules (non-negotiable)

1. **Never delete license files — anywhere in the tree, not just `usr/share/doc`.**
   This covers `copyright`, `LICENSE*`, `LICENCE*`, `COPYING*`, `COPYRIGHT*`, `NOTICE*`,
   `UNLICENSE*`. Vendored/generated source trees carry their own license files next to
   the code (Snap Store license-compliance requirement — they cover the compiled
   artifacts you still ship). Two consequences: (a) every doc-pruning `find` MUST carry
   `-not -name 'copyright'`; (b) **before `rm -rf`'ing any directory tree, relocate its
   license files first** — see `references/cleanup-patterns.md` §5.6. `compare_snaps.sh`
   flags any removed license file, but design the edit so it never removes one.
2. **Never remove a lint-flagged library without checking the dlopen suspicion list**
   (Phase 1.A). When in doubt, keep it and note it in the report.
3. **Never edit or repack the `.snap` directly.** All changes go through `snapcraft.yaml`.
4. **Never remove files injected by extensions** — command-chain, desktop-launch,
   `snap/command-chain/**`, `meta/**`. Use `snapcraft expand-extensions` to see them.
5. **Always keep the original `.snap` and yaml.** Copy the snap aside (git covers the
   yaml) so every change is comparable and revertible.
6. **If it's a git repo, edit the working tree and show a diff. Do not commit unless asked.**

## Base variable table (read `base:` FIRST)

Any override step you write must use the matching variable — mixing them fails silently.

| base | prime var | default step | notes |
|---|---|---|---|
| core20 | `$SNAPCRAFT_PRIME` | `snapcraftctl prime` | `set +u` sometimes needed |
| core22 | `$CRAFT_PRIME` (legacy names still work) | `craftctl default` | |
| core24 / core26 | `$CRAFT_PRIME` | `craftctl default` | `platforms:` not `architectures:`; `$CRAFT_ARCH_TRIPLET_BUILD_FOR` |

## Bundled resources

- `scripts/analyze_snap.sh <file.snap> [--lint-file F] [--base core2x] [--content-snap N]`
  — unpacks the snap (no root) and prints a categorized removal-candidate report
  (baseline sizes, top files/dirs, categories A–E). Read-only; never touches the snap.
- `scripts/compare_snaps.sh <old.snap> <new.snap> [--base ...] [--content-snap ...]
  [--run-lint]` — Phase 4 verification: size delta, file-list diff (flags removed
  license/`meta`/`snap` files), lint diff, and the DT_NEEDED **soname-regression** check
  (old vs new — flags only sonames that resolved before the trim but not after; ignores
  pre-existing unresolved ones). Works even when `snapcraft lint` is broken.
- `scripts/smoke_test_snap.sh <file.snap> [--cmd "<app> --version"] [--keep]` — installs
  the snap in a disposable LXD container (confinement-aware: adds `--classic` for classic
  snaps), runs the app commands, and always cleans up. Degrades to printed manual
  instructions when `lxc` is unavailable. Never installs on the host.
- `references/cleanup-patterns.md` — **the yaml pattern library** (copy-paste patterns
  §5.1–5.5, extension→content-snap map, cleanup-part rules, optional levers). Read this
  before writing any yaml edit.

---

## Phase 0 — Discover and baseline

1. **Locate the yaml**, in order: `snap/snapcraft.yaml`, `./snapcraft.yaml`,
   `build-aux/snap/snapcraft.yaml`. Locate the newest `*.snap` in the repo. If several
   snaps exist, prefer the one matching `name` + arch from the yaml; **ask if ambiguous**.
2. **Read the yaml** and note: `base` (core20/22/24/26 — changes variable names),
   `extensions` used by apps (gnome, kde-neon, …), existing `stage:`/`prime:` filters,
   and whether a `cleanup`-style part already exists (you will extend it, not duplicate).
3. **Baseline before touching anything.** Copy the `.snap` aside first, then run:
   ```bash
   scripts/analyze_snap.sh <snap> --base <base> [--content-snap <name>] \
     [--lint-file <lint.txt>]
   ```
   This captures `ls -l` size, a full file listing, top-30 files / top-15 dirs, and the
   category A–E inventory. If `snapcraft` is available, first save lint output:
   `snapcraft lint <snap> > /tmp/lint.txt 2>&1` and pass `--lint-file /tmp/lint.txt`.

## Phase 1 — Analyze (find candidates, don't edit)

`analyze_snap.sh` automates most of this. Categories:

**A. Lint-flagged unused libraries.** Parse `unused library '<path>'` lines. These come
from static ELF `DT_NEEDED` analysis. **Loud caveat:** libraries loaded at runtime via
`dlopen` are invisible to it and get **falsely flagged**. Treat as *suspicious-but-keep*
anything matching plugin-ish paths/names: `*/dri/*`, `*/gstreamer-1.0/*`,
`*/qt5/plugins/*`, `*/qt6/plugins/*`, `*/gtk-*/modules/*`, `*/alsa-lib/*`,
`*/pulseaudio/*`, `*/gio/modules/*`, `libnss*`, `libpam*`, VA-API/VDPAU drivers, and
anything the app's docs call a plugin. Everything else flagged is a strong candidate.
For each, trace it to the `stage-packages` entry that ships it (`dpkg -S` on a matching
Ubuntu container, or grep the package name): if the **whole package** is unused, drop the
stage-package; if only some files are, add `prime:` exclusions.

> **Classic-confinement signal:** if the linter flags *nearly every* staged library
> (e.g. "all 20 unused"), that's not 20 coincidences — under **classic** confinement the
> binary links libraries from the host/base at runtime, so locally-staged
> `stage-packages` are genuinely unused. Strongly suspect the whole `stage-packages` list
> is droppable; confirm with the LXD smoke test (Phase 4.4) rather than trusting the
> linter alone.

**B. Duplicates against the base snap.** Files in prime that also exist in `core24` etc.
are dead weight (the base is always mounted). Detected against `/snap/<base>/current` if
installed; otherwise it's a rebuild-time cleanup (pattern §5.3).

**C. Duplicates against extension/content snaps.** If the yaml uses e.g. the `gnome`
extension, the runtime content snap (e.g. `gnome-46-2404`) already provides a large
library set — usually the **single biggest win**. Same detection, against
`/snap/<content-snap>/current`. Also check the mesa/GL case: GL libs staged locally that
the extension provides → declarative `prime:` exclusions (§5.4).

**D. Internal duplicate libraries.** The same `.so` in two places (e.g. a vendored
payload *and* `usr/lib/...` from stage-packages). Fix with the dedupe loop (§5.2) or by
dropping the stage-package.

**E. Classic cruft** (almost always safe): `usr/share/{man,info,lintian,bug}`,
`usr/share/doc/**` **except `copyright`**, `usr/include`, `*.a`/`*.la`,
`usr/lib/**/pkgconfig`, `usr/lib/**/cmake`, unversioned `.so` dev symlinks (only when
nothing links by the unversioned name), `usr/share/themes`, icon caches, `__pycache__`,
test/example dirs, and empty dirs afterward. **`usr/share/locale` → ask the user**
(removing translations is a product decision, not cruft).

**F. Optional levers — mention, don't silently apply:** `compression: xz` vs `lzo`
(size vs startup time); stripping binaries (risky for vendor blobs). See §"Optional
levers" in the pattern library.

**G. Build scratch over-copied into prime — often the *single biggest* win.** A part's
own `override-build` frequently copies more than the runtime needs: a blanket
`cp -r <dir>` sweeps in vendored **source checkouts**, generated intermediates
(`parser.c`, `*.o`), `.git` directories, test fixtures, and docs. None of it is loaded at
runtime. The tell: a huge directory near the top of `analyze_snap.sh`'s "TOP 15
DIRECTORIES" that holds sources/`.git`/generated files rather than shipped binaries — and
its size dwarfs everything else. (Real case: Helix shipped a 2.0 GB tree-sitter
`grammars/sources/` — git checkouts + generated `parser.c` used only by
`hx --grammar build`, while only the compiled `grammars/*.so` are needed at runtime.)
Fix by **tightening the part's `override-build`**, not with a cleanup part (see Phase 3
mechanism 0 and pattern §5.7). **Two cautions:** confirm the tree really is build-only
(used by a build/dev subcommand, never `dlopen`'d or read at runtime) before removing it;
and such trees usually carry their own license files — relocate them first (rule 1, §5.6).

## Phase 2 — Propose a plan

Present candidates as a table and **get confirmation before editing** (unless the user
asked for fully autonomous operation). Never bundle "safe cruft" and "lint-flagged libs"
into one opaque change.

| Category | Path(s) / package(s) | Est. saved | Confidence | Yaml mechanism |
|---|---|---|---|---|
| E cruft | usr/share/man, doc (non-copyright) | ~12 MB | safe | cleanup part §5.1 |
| C dup   | libs provided by gnome-46-2404 | ~80 MB | needs-verification | cleanup part §5.3 |
| A lib   | liblua5.4-c++ | ~1 MB | needs-verification | drop stage-package / §5.5 |
| E locale| usr/share/locale | ~8 MB | ask-user | prime exclusion |

Confidence = `safe` / `needs-verification` / `ask-user`.

## Phase 3 — Edit snapcraft.yaml

**Read `references/cleanup-patterns.md` and use its patterns verbatim.** Mechanism
ordering, most declarative first:

0. **Tighten an over-broad copy in a part's own `override-build`** (Category G). When a
   part copies build scratch into prime, fix *what that part installs* — copy only the
   runtime files, or copy broad then prune the scratch (relocating licenses first, §5.6).
   Pattern §5.7. This is a per-part fix, not a cleanup part.
1. **Trim `stage-packages`** when a whole package is unused (also keeps CVE reporting
   accurate — dependencies are tracked through `stage-packages`).
2. **`stage:`/`prime:` negative filesets** (`- -usr/share/man/*`) for specific known paths.
3. **A `cleanup` part with `override-prime`** for pattern work (dedupe loops, doc pruning,
   content-snap dedupe). Extend an existing cleanup part; don't add a second.

Cleanup-part rules: `after:` lists **every other part**; `plugin: nil`, `source: .`;
core22/24/26 start with `craftctl default` + `$CRAFT_PRIME`, core20 uses `snapcraftctl
prime` + `$SNAPCRAFT_PRIME`; for content/base dedupe add the snap to `build-snaps:`;
comment every removal with *why*. If extensions are used, run `snapcraft
expand-extensions` and never delete what the extension injects (safety rule 4).

## Phase 4 — Rebuild, verify, iterate

1. **Rebuild** if possible (`snapcraft pack` / `snapcraft`). If the environment can't
   build (no LXD/multipass), hand back exact rebuild instructions.
2. **Compare:** `scripts/compare_snaps.sh old.snap new.snap --base <base>
   [--content-snap <name>] [--run-lint]` — check size delta, confirm nothing unexpected
   disappeared (the tool flags removed copyright/`meta`/`snap` files), diff lint warnings.
3. **Dependency sanity check** (built into `compare_snaps.sh` §4): every ELF's
   `DT_NEEDED` sonames must resolve within {snap, base, content snaps}. Any newly
   **unresolved soname = revert that removal.** This works even when `snapcraft lint` is
   broken (see below).
4. **Smoke test in a throwaway LXD container** — `scripts/smoke_test_snap.sh new.snap`.
   Do **not** `sudo snap install` on the host: that needs a password (fails
   non-interactively) and pollutes the developer's snapd. The script reads confinement
   from the snap and installs with the right flags (`--classic` for classic snaps —
   unlike snap-validator, trimming classic snaps is fully supported here), runs each
   app's `--version`/`--help`, and always tears the container down. If `lxc` is
   unavailable it prints exact manual commands instead. A missing-library error here is
   ground truth that a trim went too far — cross-check `compare_snaps.sh` §4 and revert.
5. **Iterate.** Default: apply category E (safe cruft) + confirmed A/B/C/D in one pass,
   then verify. For maximum safety, do one category at a time.

## Phase 5 — Report

Emit: before/after sizes (compressed + uncompressed), per-category savings, the exact
yaml diff, each remaining lint warning with a one-line justification (e.g. "kept:
dlopen'd Qt plugin"), and follow-ups (locale-trim decision, compression choice).

---

## Broken `snapcraft lint` runs

If lint output contains:
```
symbol lookup error: /snap/core24/current/lib/.../libc.so.6:
undefined symbol: __tunable_is_initialized, version GLIBC_PRIVATE
```
the **lint host environment is broken** (host glibc vs the mounted `core24` snap's glibc
are out of sync — typically a stale/newer core24 mismatch), **not** the snap being linted.
`compare_snaps.sh` detects this signature and says so. Guidance:

- Warnings that still print are usable, but the run is **incomplete** — treat missing
  warnings as *unknown*, not "clean".
- Remedies, in order: `sudo snap refresh core24` (and snapd); run lint inside a clean
  LXD/multipass instance; or run lint on a matching Ubuntu release.
- **Degrade gracefully to the static soname-resolution check** (Phase 4.3 /
  `compare_snaps.sh` §4), which needs no working lint host.
