# snapcraft.yaml cleanup pattern library

Copy-paste patterns for shrinking a snap by editing `snapcraft.yaml`. Every pattern
here is applied through the yaml — **never** by editing or repacking the `.snap`.

**Before copying any override step**, confirm the base and use the matching prime
variable (see the base table below and in `SKILL.md`). Mixing `$CRAFT_PRIME` and
`$SNAPCRAFT_PRIME` is a common silent failure.

## Contents

- [§Base variable table](#base-variable-table)
- [§Mechanism ordering](#mechanism-ordering-most-declarative-first)
- [§5.1 Doc/cruft pruning with the copyright exception](#51-doccruft-pruning-with-the-copyright-exception)
- [§5.2 Internal duplicate-library sweep](#52-internal-duplicate-library-sweep)
- [§5.3 Dedupe against a content/extension snap](#53-dedupe-against-a-contentextension-snap)
- [§5.4 Declarative prime exclusions for extension-provided libs](#54-declarative-prime-exclusions-for-extension-provided-libs)
- [§5.5 Acting on a library-linter warning](#55-acting-on-a-library-linter-warning)
- [§5.6 Relocate license files before deleting a tree](#56-relocate-license-files-before-deleting-a-tree)
- [§5.7 Tighten an over-broad copy (build scratch)](#57-tighten-an-over-broad-copy-build-scratch-never-belongs-in-prime)
- [§Extension → content-snap map](#extension--content-snap-map)
- [§The cleanup part: rules](#the-cleanup-part-rules)

---

## Base variable table

| base | prime var | default step | notes |
|---|---|---|---|
| core20 | `$SNAPCRAFT_PRIME` | `snapcraftctl prime` | `set +u` sometimes needed (unbound vars) |
| core22 | `$CRAFT_PRIME` (legacy names still work) | `craftctl default` | |
| core24 / core26 | `$CRAFT_PRIME` | `craftctl default` | `platforms:` not `architectures:`; use `$CRAFT_ARCH_TRIPLET_BUILD_FOR` |

Read `base:` from the yaml **first** and substitute the right variable into every
pattern below. Patterns are written for core22/24/26 (`craftctl` + `$CRAFT_PRIME`);
the core20 variant is shown where it differs.

---

## Mechanism ordering (most declarative first)

Prefer the earliest mechanism that fits:

1. **Delete/trim `stage-packages`** — when a whole package is unused. Most declarative;
   also keeps CVE reporting accurate (dependencies tracked via `stage-packages` +
   `SNAPCRAFT_BUILD_INFO=1`). Best first choice when an entire package can go.
2. **`stage:` / `prime:` negative filesets** — `- -usr/share/man/*` style, on the part
   that ships the files. Best for specific, known paths.
3. **A `cleanup` part with `override-prime`** — for pattern-based work: dedupe loops,
   doc pruning with the copyright exception, empty-dir removal, content-snap dedupe.
   If a cleanup part already exists, **extend it** — do not add a second one.

---

## 5.1 Doc/cruft pruning with the copyright exception

From the zoom-snap. Removes man pages, lintian/bug metadata, themes, and docs —
**keeping every `copyright` file** (Snap Store license-compliance requirement).

```yaml
  cleanup:
    source: .
    plugin: nil
    after: [ <all-other-parts> ]
    override-prime: |
      craftctl default
      # clean up unused cruft
      for CRUFT in bug lintian man themes; do
        rm -rf $CRAFT_PRIME/usr/share/$CRUFT
      done
      # drop all docs except licenses
      find $CRAFT_PRIME/usr/share/doc/ -type f -not -name 'copyright' -delete
      find $CRAFT_PRIME/usr/share -type d -empty -delete
```

**core20 variant:** replace `craftctl default` with `snapcraftctl prime` and every
`$CRAFT_PRIME` with `$SNAPCRAFT_PRIME`.

> The `-not -name 'copyright'` guard is mandatory on every doc-pruning `find`. Never
> write a doc-deletion command without it.

---

## 5.2 Internal duplicate-library sweep

From the zoom-snap. When the same `.so` ships both in a vendored app payload
(e.g. `zoom/`) **and** under `usr/lib/...` from stage-packages, drop the
stage-packages copy. Add this inside the `cleanup` part's `override-prime`:

```yaml
      # remove libs duplicated between the vendored payload and stage-packages
      for lib in $(find $CRAFT_PRIME/<payload-dir>/ -type f -name "*.so*"); do
        for files in $(find $CRAFT_PRIME/usr $CRAFT_PRIME/lib -name "*$(basename $lib)*" -type f); do
          rm -fv $files
        done
      done
```

Replace `<payload-dir>` with the vendored directory (find it in category D of
`analyze_snap.sh`). Verify afterward with `compare_snaps.sh` — if the payload copy
and the stage-packages copy differ in version, keep the one the app actually links.

---

## 5.3 Dedupe against a content/extension snap

From `snapcraft-forum-client` (ogra1's trick). The single biggest win for
extension-using snaps: the runtime content snap (e.g. `gnome-46-2404`) already
provides a huge library set, so any file also present there is dead weight.

```yaml
  cleanup:
    after: [ <all-other-parts> ]
    plugin: nil
    build-snaps: [ gnome-46-2404 ]   # match the extension's runtime content snap
    override-prime: |
      craftctl default
      set -eux
      cd /snap/gnome-46-2404/current
      find . -type f,l -exec rm -f $CRAFT_PRIME/{} \;
      find $CRAFT_PRIME/usr/share/doc/ -type f -not -name 'copyright' -delete
      find $CRAFT_PRIME/usr/share -type d -empty -delete
```

- The same pattern works **against the base snap**: add it to `build-snaps` (or rely on
  it being mounted) and `cd /snap/core24/current`.
- Pick the content snap from `snapcraft expand-extensions` output — **do not hardcode**
  a version. See the map below.
- `find . -type f,l` uses GNU find's comma syntax (files *and* symlinks); it deletes the
  corresponding path under `$CRAFT_PRIME`, leaving anything unique to your snap intact.

---

## 5.4 Declarative prime exclusions for extension-provided libs

From the zoom-snap. When only a known set of libraries is provided by the extension
(classic case: mesa/GL), exclude them declaratively on the part that stages them —
no override script needed.

```yaml
    stage:
      - -usr/lib/x86_64-linux-gnu/libharfbuzz.*
    prime:  # remove all of mesa, provided by the extension
      - -usr/lib/x86_64-linux-gnu/dri
      - -usr/lib/x86_64-linux-gnu/libgbm.so.*
      - -usr/lib/x86_64-linux-gnu/libEGL*
      - -usr/lib/x86_64-linux-gnu/libGL*
      - -usr/lib/x86_64-linux-gnu/libglapi.so.*
```

Prefer `$CRAFT_ARCH_TRIPLET_BUILD_FOR` over a hardcoded `x86_64-linux-gnu` when the
snap declares multiple platforms — but note: filesets in `stage:`/`prime:` do **not**
expand shell/craft variables, so for multi-arch you must either list per-arch entries
or move the removal into an `override-prime` step that can use the variable.

---

## 5.5 Acting on a library-linter warning

For a warning like
`unused library 'usr/lib/x86_64-linux-gnu/liblua5.4-c++.so.0.0.0'`:

1. **Check the dlopen suspicion list first** (see `SKILL.md` §Phase 1.A). A plain shared
   lib like `liblua5.4-c++` is *not* on the list → likely a true positive dragged in as a
   dependency of a lua-related stage-package. Anything matching plugin paths
   (`*/dri/*`, `*/gstreamer-1.0/*`, `*/qt*/plugins/*`, `libnss*`, VA-API drivers, …) is
   **keep-by-default** — the linter can't see `dlopen` loads.
2. **Find the owning package.** If nothing else from it is used, drop it from
   `stage-packages`. Otherwise add a targeted prime exclusion:
   ```yaml
   prime:
     - -usr/lib/*/liblua5.4-c++.so.*
   ```
3. **If the team decides to keep it anyway, silence it deliberately** (don't just leave a
   perpetual warning):
   ```yaml
   lint:
     ignore:
       library:
         - usr/lib/**/liblua5.4-c++.so.*
   ```

---

## 5.6 Relocate license files before deleting a tree

**Hard safety rule 1** forbids removing any license file — and license files live
*inside* source/vendor trees, not only under `usr/share/doc`. When a big removal target
is a whole directory (a vendored source checkout, a bundled dependency, a grammar
`sources/` tree), a blunt `rm -rf` will take the upstream `LICENSE`/`COPYING`/`NOTICE`
files with it. Those files cover the compiled artifacts you keep shipping, so they must
survive.

**Pattern: sweep the licenses into a `licenses/` sibling first, then delete.** (Real case:
Helix's tree-sitter `grammars/sources/` — ~2 GB of git checkouts + generated `parser.c`,
carrying 314 grammar license files. The compiled `grammars/*.so` ship; the sources don't.)

```yaml
      # About to drop a large source/vendor tree. Preserve its license files first —
      # they cover the compiled artifacts we still ship (Snap Store compliance).
      DOOMED=$CRAFT_PRIME/lib/helix/runtime/grammars/sources
      KEEP=$CRAFT_PRIME/lib/helix/runtime/grammars/licenses
      ( cd "$DOOMED" && find . -type f \
          \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' \
             -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' -o -iname 'UNLICENSE*' \) \
          -exec install -Dm644 {} "$KEEP"/{} \; )
      rm -rf "$DOOMED"
```

This can appear in the part's own `override-build` (relocate right after the copy that
introduced the tree) or in the `cleanup` part's `override-prime`. Either way: **relocate,
then delete.** After rebuild, `compare_snaps.sh` will flag any license file that slipped
through — if it does, the sweep missed a filename pattern; widen the `-iname` list.

---

## 5.7 Tighten an over-broad copy (build scratch never belongs in prime)

Often the biggest single win isn't a library at all — it's a part copying **more than the
runtime needs** into `$CRAFT_PART_INSTALL`. Blanket `cp -r <dir>` sweeps in build scratch:
vendored source checkouts, generated intermediates (`parser.c`, `*.o`), `.git` dirs, test
fixtures. This is **Category G** in `SKILL.md` §Phase 1.

The fix lives in the part's own `override-build` (or `override-prime`), not in a separate
cleanup part — you're correcting *what that part installs*. Two shapes:

**(a) Copy only what's needed** instead of the whole tree:

```yaml
    override-build: |
      craftctl default
      # Ship only the compiled grammars + queries, NOT grammars/sources (build-time only).
      install -Dm755 -d $CRAFT_PART_INSTALL/lib/helix/runtime/grammars
      cp -r runtime/grammars/*.so $CRAFT_PART_INSTALL/lib/helix/runtime/grammars/
      cp -r runtime/queries       $CRAFT_PART_INSTALL/lib/helix/runtime/
```

**(b) Copy broad, then prune the scratch** — when the build tool insists on a full copy.
Relocate licenses first (§5.6) if the pruned tree contains any:

```yaml
    override-build: |
      craftctl default
      cp -r runtime/grammars $CRAFT_PART_INSTALL/lib/helix/runtime/
      # grammars/sources = tree-sitter git checkouts + generated parser.c (~2 GB),
      # used only by `hx --grammar build`, never at runtime. Preserve licenses, then drop.
      GRAMMARS=$CRAFT_PART_INSTALL/lib/helix/runtime/grammars
      ( cd $GRAMMARS/sources && find . -type f \
          \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' \
             -o -iname 'NOTICE*' -o -iname 'UNLICENSE*' \) \
          -exec install -Dm644 {} $GRAMMARS/licenses/{} \; )
      rm -rf $GRAMMARS/sources
```

Confirm the pruned content really is build-only (used by a build/dev subcommand, not
`dlopen`'d or read at runtime) before removing it — then verify with the smoke test.

---

## Extension → content-snap map

Always confirm with `snapcraft expand-extensions` (it prints the exact `build-snaps`
and command-chain the extension injects). Common mappings:

| extension | base | typical runtime content snap |
|---|---|---|
| `gnome`   | core24 | `gnome-46-2404` |
| `gnome`   | core22 | `gnome-42-2204` |
| `kde-neon` | core22 | `kf5-5-XX-qt-5-XX-core22` (Qt5) |
| `kde-neon-6` | core24 | `kf6-core24` / matching Qt6 content snap |

Versions move over time — the table is a starting point, not a source of truth. Read the
actual `build-snaps:` line from `snapcraft expand-extensions` and use that name.

> Never delete files the extension's own parts add: command-chain scripts,
> `desktop-launch`, anything under `snap/command-chain/**` or `meta/**`. `expand-extensions`
> shows exactly what the extension injects — treat those paths as off-limits.

---

## The cleanup part: rules

- `after:` must list **every other part**, so the cleanup runs last in the prime step.
- `plugin: nil` and `source: .` (or no source).
- core22/24/26: start `override-prime` with `craftctl default`, use `$CRAFT_PRIME`.
  core20: use `snapcraftctl prime` (no `craftctl`) and `$SNAPCRAFT_PRIME`; add `set +u`
  if unbound-variable errors appear.
- For content-snap / base dedupe, add the snap to the cleanup part's `build-snaps:` so
  it is mounted inside the build environment.
- Comment every removal loop with **why** — e.g. `# provided by gnome-46-2404`.
- Only one cleanup part. If one already exists, extend its `override-prime`.

---

## Optional levers (surface, don't silently apply)

- **Compression** — `xz` (smaller file, slower first start) vs `lzo` (larger, faster
  start). Set at top level: `compression: xz`. This trades startup latency for size;
  present the tradeoff and let the user choose.
- **Stripping binaries** — an `override-build`/`override-prime` `strip` pass can shrink
  ELF files, but is risky for vendor blobs and prebuilt binaries. Mention only; do not
  apply automatically.
- **Locale trimming** — removing `usr/share/locale/*` drops translations. This is a
  product decision, not cruft; ask the user before removing.
