# Rootfs Modifications → Override Steps Guide

When making a snap work from an OCI container, manual changes to the rootfs or
`prime/` directory are often discovered during build and runtime iteration. This
guide explains how to **capture every such change as an `override-build:` or
`override-prime:` step** in `snapcraft.yaml`, so that the build is fully
reproducible and the rootfs can be replaced with an updated image without any
manual pre-processing.

---

## The Core Principle

> **Every manual change to `rootfs/` or `prime/` must have an equivalent
> override step in `snapcraft.yaml`.** Never let ad-hoc rootfs modifications
> exist outside the recipe.
>
> **Every change to a script run by a part must be followed by
> `snapcraft clean <part-name> --use-lxd --build-for <target_arch>` before the
> next rebuild.** This includes scripts called from `override-build:` or
> `override-prime:` such as `patch_scripts/*.sh` and `build_scripts/*.sh`.
> Snapcraft may otherwise reuse the old staged script from the part cache.

The goal: `snapcraft` (re-)applies all necessary mutations automatically on
every build. When a new OCI image is dropped in, only the rootfs is replaced;
the snapcraft recipe stays the same and produces a correct snap.

---

## Snapcraft Variables Reference

Use these variables inside override scripts instead of hardcoding paths:

| Variable | Meaning | Typical use |
|---|---|---|
| `$SNAPCRAFT_PART_INSTALL` | Staging area after build/install step | Patch binaries, create symlinks, set permissions |
| `$SNAPCRAFT_PART_SRC` | Source directory (pre-build) | Rarely needed; prefer PART_INSTALL |
| `$SNAPCRAFT_PRIME` | Prime directory (after priming) | Post-prime config mutations |
| `$SNAP` | Runtime snap root (`/snap/<name>/current`) | Used inside runtime scripts, **not** in override steps |
| `$SNAP_COMMON` | Runtime writable data dir | Used inside runtime scripts, **not** in override steps |

Override steps run at **build time**, so `$SNAP` and `$SNAP_COMMON` are not yet
meaningful. Use `$SNAPCRAFT_PART_INSTALL` for the vast majority of mutations.

---

## Choosing `override-build` vs `override-prime`

```
Did you modify rootfs/ or prime/ before it was installed?
    |
    ├─ Yes, I changed a file that the snapcraft part installs (binary, lib, symlink, config)
    |       → use override-build
    |
    └─ Yes, I changed a file in prime/ after the build was complete
           (e.g. tweaked a config that appears in prime/ but not in any part's install dir)
               → use override-prime
```

**Prefer `override-build`** — it runs before priming, is part-scoped, and is
easier to clean with `snapcraft clean <part-name>`.

Use **`override-prime`** only for post-prime mutations that cannot be expressed
in the build step (rare: e.g. deleting files that multiple parts contribute to
`prime/`, or editing a file that is assembled from multiple sources).

---

## ⚠️ Ordering Rule for `dump` Plugin Parts: Mutations Go AFTER `craftctl default`

> **Critical for the `oci-container` part and any other part using `plugin: dump`.**

The `dump` plugin copies source files into `$CRAFT_PART_INSTALL` as part of
`craftctl default`. Before `craftctl default` runs, `$CRAFT_PART_INSTALL` is
**empty** — any `sed -i`, `chmod`, `rm`, or other mutation targeting files in
`$CRAFT_PART_INSTALL` placed *before* `craftctl default` will silently do
nothing because the target files do not yet exist.

**Correct ordering:**
```yaml
override-build: |
  # ... build scripts that operate on $CRAFT_PART_BUILD (populated from source) ...
  "$CRAFT_PROJECT_DIR"/build_scripts/replace_absolute_symlinks.sh
  "$CRAFT_PROJECT_DIR"/build_scripts/patch_interpreter.sh
  "$CRAFT_PROJECT_DIR"/build_scripts/embed_rpath.sh
  "$CRAFT_PROJECT_DIR"/build_scripts/create_wrapper.sh

  # craftctl default copies $CRAFT_PART_BUILD → $CRAFT_PART_INSTALL
  craftctl default

  # Mutations on config files (e.g. myapp.conf) go HERE — after craftctl default
  # so $CRAFT_PART_INSTALL is fully populated.
  CONF="$CRAFT_PART_INSTALL/etc/myapp/myapp.conf"
  if [ -f "$CONF" ]; then
    sed -i 's|/var/run/myapp|/var/snap/myapp/current/run|' "$CONF"
  fi
```

**Wrong — mutation before craftctl default silently does nothing:**
```yaml
override-build: |
  # BUG: $CRAFT_PART_INSTALL/etc/myapp/myapp.conf does not exist yet
  sed -i 's|/var/run/myapp|/var/snap/myapp/current/run|' \
    "$CRAFT_PART_INSTALL/etc/myapp/myapp.conf"
  craftctl default  # copies files, but the sed already ran on a non-existent file
```

The `oci-container` build scripts (`replace_absolute_symlinks.sh`,
`patch_interpreter.sh`, `embed_rpath.sh`, `create_wrapper.sh`) operate on
`$CRAFT_PART_BUILD` (the unpacked source tree), which *is* populated before
`craftctl default`. This is why they run before `craftctl default` in the
generated template. Any **additional** config-file patches you add should be
placed after `craftctl default`.

---

## Pattern Catalog

### 1. ELF Interpreter Patching

**Situation:** The binary's ELF interpreter points to an absolute path that
does not exist inside the snap (e.g. `/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2`).

**Manual change made:**
```bash
patchelf --set-interpreter /absolute/path/to/ld-linux.so.2 rootfs/usr/bin/myapp
```

**Equivalent override-build step:**
```yaml
parts:
  oci-container:
    plugin: dump
    source: rootfs/
    override-build: |
      craftctl default
      patchelf --set-interpreter \
        $SNAPCRAFT_PART_INSTALL/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
        $SNAPCRAFT_PART_INSTALL/usr/bin/myapp
```

**Notes:**
- The interpreter path in `--set-interpreter` must be absolute at **runtime**
  (i.e. the snap-mounted path: `/snap/<name>/current/lib/…`). However, when
  patching during build, point to `$SNAPCRAFT_PART_INSTALL/…` — snapcraft
  resolves this to the runtime path automatically via layout.
- If `patchelf` is not available in the build environment, add it as a
  `build-package`:
  ```yaml
  build-packages: [patchelf]
  ```

---

### 2. RPATH / RUNPATH Patching

**Situation:** The binary's RPATH points to a host library path that will be
wrong inside the snap.

**Manual change made:**
```bash
patchelf --set-rpath '$ORIGIN/../lib' rootfs/usr/bin/myapp
```

**Equivalent override-build step:**
```yaml
override-build: |
  craftctl default
  patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../../lib/x86_64-linux-gnu' \
    $SNAPCRAFT_PART_INSTALL/usr/bin/myapp
```

**Note:** `$ORIGIN` is an ELF token (not a shell variable); quote it carefully
so the shell does not expand it.

> ⚠️ **CRITICAL: Only patch ELF executables (ET_EXEC) — NEVER patch shared
> libraries (ET_DYN / .so files).**
>
> Applying `patchelf --set-rpath` to shared libraries (`.so` files) corrupts
> them. In particular, patching `ld-linux.so.2` (the dynamic linker itself)
> makes it non-functional, causing an immediate SIGSEGV for every binary that
> uses it. If you accidentally patch `.so` files, restore them from a backup
> (e.g. re-extract the rootfs) — patchelf's changes are not reversible.
>
> **How to filter to ET_EXEC only:**
> ```bash
> for f in $(find $SNAPCRAFT_PART_INSTALL -type f -executable); do
>   elf_type=$(readelf -h "$f" 2>/dev/null | sed -n 's/.*Type:[[:space:]]*\([A-Z_]*\).*/\1/p')
>   [ "$elf_type" = "ET_EXEC" ] || continue
>   patchelf --force-rpath --set-rpath "$rpath" "$f"
> done
> ```
>
> The `embed_rpath.sh` build script in this repository implements this filter
> automatically and should be used instead of manual patchelf calls. It also
> uses `--force-rpath` to write `DT_RPATH` (higher priority than `DT_RUNPATH`,
> takes effect before `LD_LIBRARY_PATH`).

**Why RPATH embedding is preferred over LD_LIBRARY_PATH:**
When the OCI image's glibc version differs from the base snap's glibc version,
any subprocess forked via `popen()` or `system()` in a C binary inherits
`LD_LIBRARY_PATH`. These subprocesses run the BASE SNAP's `/bin/sh` (not the
OCI shell). The base shell will crash with `GLIBC_X.Y not found` if it tries to
load the OCI image's older libraries. Embedding RPATH avoids this entirely —
`LD_LIBRARY_PATH` is not needed at the environment level at all.

**For bulk patching of all ET_EXEC binaries**, use `embed_rpath.sh`:
```yaml
override-build: |
  craftctl default
  "$CRAFT_PROJECT_DIR"/build_scripts/patch_interpreter.sh
  "$CRAFT_PROJECT_DIR"/build_scripts/embed_rpath.sh
  "$CRAFT_PROJECT_DIR"/build_scripts/create_wrapper.sh
```

---

### 3. Symlink Creation / Fixing

**Situation:** The application expects a symlink that is absent or wrong in the
rootfs.

**Manual change made:**
```bash
ln -sf libfoo.so.1.2.3 rootfs/usr/lib/libfoo.so.1
ln -sf /usr/lib/libfoo.so.1 rootfs/usr/lib/x86_64-linux-gnu/libfoo.so.1
```

**Equivalent override-build step:**
```yaml
override-build: |
  craftctl default
  # Relative symlink (preferred — stays valid inside the snap)
  ln -sf libfoo.so.1.2.3 \
    $SNAPCRAFT_PART_INSTALL/usr/lib/libfoo.so.1
  # Cross-directory symlink
  ln -sfT $SNAPCRAFT_PART_INSTALL/usr/lib/libfoo.so.1 \
    $SNAPCRAFT_PART_INSTALL/usr/lib/x86_64-linux-gnu/libfoo.so.1
```

**Avoid absolute symlinks** that point to `/usr/lib/…` — they will break at
runtime because the snap is mounted under `/snap/<name>/current/`. Use
relative symlinks or paths prefixed with `$SNAPCRAFT_PART_INSTALL`.

---

### 4. File Permission Changes

**Situation:** A binary or script does not have execute permission in the rootfs.

**Manual change made:**
```bash
chmod 755 rootfs/usr/bin/myapp
chmod 644 rootfs/etc/myapp/myapp.conf
```

**Equivalent override-build step:**
```yaml
override-build: |
  craftctl default
  chmod 755 $SNAPCRAFT_PART_INSTALL/usr/bin/myapp
  chmod 644 $SNAPCRAFT_PART_INSTALL/etc/myapp/myapp.conf
```

---

### 5. In-file Content Mutations (sed / awk)

**Situation:** A config file or script contains hardcoded paths that must be
rewritten for snap compatibility.

**Manual change made:**
```bash
sed -i 's|/var/lib/myapp|/var/snap/myapp/common|g' rootfs/etc/myapp/myapp.conf
sed -i 's|/usr/share/myapp|/snap/myapp/current/usr/share/myapp|g' rootfs/etc/myapp/myapp.conf
```

**Equivalent override-build step (build-time variable form):**
```yaml
override-build: |
  craftctl default
  # Writable data → $SNAP_COMMON at runtime; use the literal string here
  sed -i 's|/var/lib/myapp|$SNAP_COMMON/myapp|g' \
    $SNAPCRAFT_PART_INSTALL/etc/myapp/myapp.conf
  # Read-only snap content → $SNAP at runtime
  sed -i 's|/usr/share/myapp|$SNAP/usr/share/myapp|g' \
    $SNAPCRAFT_PART_INSTALL/etc/myapp/myapp.conf
```

> ⚠️ **Shell quoting:** The `sed` replacement strings contain `$SNAP_COMMON`
> and `$SNAP`, which are runtime shell variables. They must appear **literally**
> in the output file — use **single quotes** around the sed expression, or
> escape `$` as `\$`, so the build-time shell does not expand them.

---

### 6. File Deletion

**Situation:** A file in the rootfs must be removed before the snap is built
(e.g. a conflicting config that the snap ships via another mechanism).

**Manual change made:**
```bash
rm rootfs/etc/myapp/hardcoded.conf
```

**Equivalent override-build step:**
```yaml
override-build: |
  craftctl default
  rm -f $SNAPCRAFT_PART_INSTALL/etc/myapp/hardcoded.conf
```

---

### 7. Adding a File Not Present in the Rootfs

**Situation:** A wrapper script, environment file, or helper binary must be
injected into the snap.

**Approach:** Do not add files directly to `rootfs/`. Instead, create a
**separate part** that sources from a `local/` or `snap/` directory:

```yaml
parts:
  oci-container:
    plugin: dump
    source: rootfs/

  local-overrides:
    plugin: dump
    source: snap/local/         # files committed alongside snapcraft.yaml
    organize:
      library_wrapper.sh: usr/bin/library_wrapper.sh
      env-exporter.sh: usr/bin/env-exporter.sh
```

This keeps the rootfs pristine and the additions version-controlled alongside
the recipe.

If the file is small and self-contained, it can also be written by the override
step:

```yaml
override-build: |
  craftctl default
  cat > $SNAPCRAFT_PART_INSTALL/usr/bin/library_wrapper.sh <<'EOF'
  #!/bin/bash
  export LD_LIBRARY_PATH=$SNAP/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
  exec "$@"
  EOF
  chmod 755 $SNAPCRAFT_PART_INSTALL/usr/bin/library_wrapper.sh
```

---

### 7b. Staged OCI coreutils contaminating the build PATH

**Situation:** The OCI image uses the coreutils-single multicall pattern, common
on Amazon Linux 2023 and RHEL 9+. Each applet (`cp`, `mkdir`, `id`, …) is a
tiny shebang script pointing at the coreutils binary:

```
#!/usr/bin/coreutils --coreutils-prog-shebang=cp
```

A `patch_coreutils_shebang.sh` `override-build` step rewrites those shebangs
from `/usr/bin/coreutils` to `/snap/<name>/current/usr/bin/coreutils` so the
OCI image's own coreutils binary (interpreter-patched and RPATH-embedded) is
used at runtime. After `oci-container` is staged, the rewritten applets land in
`$CRAFT_STAGE/usr/bin`. Snapcraft puts `$CRAFT_STAGE` on the build `PATH` for
subsequent parts. When a later part's `override-build` calls `craftctl default`,
the dump plugin resolves `cp --archive` via PATH and picks up the broken staged
applet whose shebang now points at the not-yet-installed snap path. The build
aborts with:

```
/root/stage/usr/bin/cp: /snap/<name>/current/usr/bin/coreutils:
    bad interpreter: No such file or directory
```

**Manual change that would be wrong:** letting a local/auxiliary part use the
default `craftctl default` after `oci-container` is staged.

**Correct fix — use absolute host paths in `override-build` for auxiliary parts:**

```yaml
parts:
  local-auxiliary:
    plugin: dump
    source: snap/local
    organize:
      myfile.sh: usr/bin/myfile.sh
    stage:
      - usr/bin/myfile.sh
    override-build: |
      # Do NOT use craftctl default here: it would resolve cp/install via PATH
      # and pick up the staged OCI coreutils applets patched by
      # patch_coreutils_shebang.sh, which point at a non-existent runtime path.
      # Use absolute host paths to bypass PATH resolution entirely.
      /bin/mkdir -p "$CRAFT_PART_INSTALL"
      /bin/cp -a "$CRAFT_PART_SRC"/. "$CRAFT_PART_INSTALL"/
```

**Notes:**
- Only affects parts built **after** `oci-container` is staged (the default
  for parts without an explicit `after:` declaration).
- Snapcraft's `organize:` and `stage:` lifecycle steps run independently of
  `craftctl default` and fire correctly even when `craftctl default` is
  replaced entirely.
- Alternatively, declare `after: []` on the auxiliary part to build it before
  `oci-container` is staged — but only when the auxiliary part's source does
  not depend on OCI-staged content.

---

### 8. Directory Creation

**Situation:** The application expects a directory that does not exist in the
rootfs (typically a writable runtime directory).

**Manual change made:**
```bash
mkdir -p rootfs/var/lib/myapp
```

**Equivalent override-build step:**
```yaml
override-build: |
  craftctl default
  mkdir -p $SNAPCRAFT_PART_INSTALL/var/lib/myapp
```

> **Note:** For writable runtime directories, prefer a `layout` entry pointing
> to `$SNAP_COMMON/…` rather than including the directory in the snap itself.
> The override step above is appropriate only for read-only directories that
> the snap ships with static content.

---

## Modularising Override Steps with patch_scripts/

When the set of rootfs mutations grows beyond a handful of commands, or when the
same mutation must be applied across several projects, embedding every command
directly in the `override-build:` YAML block becomes hard to read, test, and
maintain. A robust and repeatable alternative is to **extract each logical
mutation into its own small shell script** inside a dedicated `patch_scripts/`
folder, and have `override-build:` simply call those scripts.

### When to use this approach

- More than ~3–4 distinct mutation commands in a single `override-build:` block.
- The same mutation (e.g. RPATH embedding, interpreter patching) is needed in
  multiple snaps or parts.
- You want to test or re-run a single mutation step without triggering a full
  `snapcraft clean` / rebuild cycle.
- The mutation logic requires loops, conditionals, or helper functions that are
  unwieldy in inline YAML strings.

### Folder layout

Create a `patch_scripts/` directory alongside `snapcraft.yaml`:

```
snap/
  snapcraft.yaml
patch_scripts/
  patch_interpreter.sh      # patchelf --set-interpreter for all ET_EXEC binaries
  embed_rpath.sh            # patchelf --force-rpath for all ET_EXEC binaries
  fix_permissions.sh        # chmod / chown mutations
  fix_symlinks.sh           # ln -sf adjustments
  patch_configs.sh          # sed / awk in-file content mutations
  # ... one script per logical concern
```

Each script is committed alongside the snap recipe and version-controlled — the
rootfs can be replaced by a new OCI image and `snapcraft` will re-apply all
mutations automatically.

Whenever one of these scripts is created or edited, clean the part that invokes
it before rebuilding:

```bash
snapcraft clean <part-name> --use-lxd --build-for <target_arch>
snapcraft --use-lxd --build-for <target_arch>
```

### Script conventions

Each patch script should:

1. Accept `$SNAPCRAFT_PART_INSTALL` (or the relevant snapcraft variable) from the
   environment — **never hardcode absolute host paths**.
2. Exit non-zero on failure so `snapcraft` aborts the build immediately.
3. Be idempotent (safe to run more than once; use `-f` on `rm`, `ln -sf`, etc.).
4. Print a short status line to stdout so the build log shows what was patched.

Minimal template:

```bash
#!/bin/bash
set -euo pipefail
INSTALL="${SNAPCRAFT_PART_INSTALL:?SNAPCRAFT_PART_INSTALL is not set}"

echo "[patch_scripts/fix_permissions.sh] applying permission fixes"
chmod 755 "$INSTALL/usr/bin/myapp"
chmod 644 "$INSTALL/etc/myapp/myapp.conf"
```

### Calling scripts from override-build

Reference the scripts via `$CRAFT_PROJECT_DIR` so the path is always resolved
correctly regardless of the build backend (LXD, Multipass, destructive):

```yaml
parts:
  oci-container:
    plugin: dump
    source: rootfs/
    override-build: |
      craftctl default
      "$CRAFT_PROJECT_DIR"/patch_scripts/patch_interpreter.sh
      "$CRAFT_PROJECT_DIR"/patch_scripts/embed_rpath.sh
      "$CRAFT_PROJECT_DIR"/patch_scripts/fix_permissions.sh
      "$CRAFT_PROJECT_DIR"/patch_scripts/fix_symlinks.sh
      "$CRAFT_PROJECT_DIR"/patch_scripts/patch_configs.sh
```

> **`$CRAFT_PROJECT_DIR` vs `$SNAPCRAFT_PROJECT_DIR`:** In snapcraft ≥ 7 / core24
> projects, use `$CRAFT_PROJECT_DIR`. In older snapcraft 6 / core22 projects, use
> `$SNAPCRAFT_PROJECT_DIR`. Both point to the directory containing `snapcraft.yaml`.

### Relationship to inline override commands

The pattern catalog in the preceding sections shows how each mutation maps to a
set of shell commands. Those commands can be used directly in the `override-build:`
YAML **or** placed inside a `patch_scripts/` script — both approaches are correct.
Choose whichever keeps the recipe most readable:

| Condition | Recommendation |
|---|---|
| 1–3 simple, one-liner mutations | Inline in `override-build:` |
| 4+ mutations, or complex logic | Extract to `patch_scripts/` scripts |
| Same mutation used in multiple parts/snaps | Always extract to a shared script |

---

## Using `patch_snapcraft.py` to Apply Override Steps

The `snap-packager`'s `scripts/patch_snapcraft.py` supports adding override steps directly:

```bash
# Dry run — review before applying (run the snap-packager script)
python3 snap-packager/scripts/patch_snapcraft.py \
  --snapcraft snap/snapcraft.yaml \
  --part oci-container \
  --override-build "patchelf --set-interpreter \$SNAPCRAFT_PART_INSTALL/lib/ld.so \$SNAPCRAFT_PART_INSTALL/usr/bin/myapp" \
  --override-build "chmod 755 \$SNAPCRAFT_PART_INSTALL/usr/bin/myapp" \
  --dry-run

# Apply for real
python3 snap-packager/scripts/patch_snapcraft.py \
  --snapcraft snap/snapcraft.yaml \
  --part oci-container \
  --override-build "patchelf --set-interpreter \$SNAPCRAFT_PART_INSTALL/lib/ld.so \$SNAPCRAFT_PART_INSTALL/usr/bin/myapp" \
  --override-build "chmod 755 \$SNAPCRAFT_PART_INSTALL/usr/bin/myapp"
```

**Script behaviour:**
- Ensures `craftctl default` is the first line.
- Skips commands already present (idempotent).
- Creates a `.bak` backup before writing.
- `--part` is required when using `--override-build` or `--override-prime`.

**Exit codes:**
- Exit 5 — named `--part` not found in `snapcraft.yaml`
- Exit 6 — `--override-build`/`--override-prime` used without `--part`

---

## Override Step Ordering

When multiple override commands are needed, order them to avoid dependency
issues:

1. `craftctl default` (always first)
2. Permission fixes (`chmod`, `chown`)
3. Symlink creation / removal
4. Binary patching (`patchelf`)
5. Config file mutations (`sed`, `awk`, file writes)
6. Directory creation
7. File deletions

---

## Verification: Does the Override Reproduce the Manual Change?

After adding override steps, or after creating/editing any script that those
steps call, verify they are equivalent to the manual change:

```bash
# Clean just the affected part and rebuild
snapcraft clean oci-container --use-lxd --build-for <target_arch>
snapcraft --use-lxd --build-for <target_arch>

# Inspect the result in prime/
ldd prime/usr/bin/myapp          # ELF interpreter correct?
ls -la prime/usr/lib/libfoo.so*  # symlinks correct?
cat prime/etc/myapp/myapp.conf   # config mutations applied?
```

Then replace `rootfs/` with the new version of the OCI image (extracted to the
same path) and rebuild — the snap must build and run correctly without any
manual rootfs intervention.
