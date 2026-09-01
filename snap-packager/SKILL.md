---
name: snap-packager
description: >
  Reads a snap-analysis.json file produced by the snap-analyzer skill and generates all files
  needed to package the application as a snap: snapcraft.yaml targeting core24 and snapcraft 8.x,
  lifecycle hooks, and a SNAP_PACKAGING.md guide documenting how to build, install, and test the
  snap and which connectors must be enabled. Runs snapcraft pack and iterates until the build
  succeeds. WHEN: package as snap, create snapcraft.yaml, snap this application, snap packaging,
  convert to snap, create snap, add snap support, snap confinement, snapcraft configuration,
  snap interfaces, snap hooks, snap build, package with snapcraft, core24 snap, snapcraft 8,
  make a snap, write snapcraft yaml, snap containerize, generate snap files,
  OCI config to snap, container to snap, snap platforms build-for, system-usernames,
  snap override-build, snap content interface, snap configure hook from OCI.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.3.0"
  summary: "Reads snap-analysis.json and generates snapcraft.yaml, hooks, and a packaging guide, then builds the snap; renders OCI recipes when the analysis has an oci key."
  tags:
    - snap
    - snapcraft
    - packaging
    - canonical
    - linux
    - core24
---

# Snap Packager

## Overview

Reads `snap-analysis.json` (written by the `snap-analyzer` **or** `snap-oci-analyzer`
skill) and produces:
- `snap/snapcraft.yaml` — the snap manifest (core24, snapcraft 8.x)
- `snap/hooks/<hook>` — lifecycle hooks (only those listed in the analysis)
- `SNAP_PACKAGING.md` — build instructions, interface connection commands, and testing guide

> **This skill is the *only* writer of `snap/snapcraft.yaml`** in the pipeline. Both
> analyzers emit *facts*; the validator only *reports*. Initial rendering and top-level
> structures such as `platforms:`, `hooks:`, `slots:`, and named top-level `plugs:` are
> written here; supported incremental app plugs, layouts, and part overrides use
> `scripts/patch_snapcraft.py` (see Step 2.4). **Never write to a container `rootfs/`
> directly**; a change the image needs is encoded as an `override-build:`/`override-prime:`
> step, never applied to the source tree.

> **Two input shapes, one contract.** If `snap-analysis.json` has an `oci` key it came
> from `snap-oci-analyzer` (a container image) — take the **OCI rendering path** (Step 2a,
> OCI variant). Otherwise it came from `snap-analyzer` (source code) — take the original
> path unchanged. Schema `1.0` (no `oci` key) and `1.1` without an `oci` key both behave
> exactly as before.

> **Locating the analysis file:** `snap-analyzer` writes it to a project-scoped `/tmp`
> path. Resolve it in this order and use the first that exists:
>
> ```bash
> ANALYSIS_FILE="/tmp/snap-analysis-$(basename "$PWD").json"
> [ -f "$ANALYSIS_FILE" ] || ANALYSIS_FILE="./snap-analysis.json"   # legacy fallback
> ```
>
> If neither exists, stop and instruct the user to run the `snap-analyzer` skill first.

## Workflow

> **Patch mode:** If `snap-validation-results.json` is present in the project root with
> `"clean": false`, skip to **Step 2b** — patch `snap/snapcraft.yaml` based on the results
> (denials and devmode findings for any snap; reproducibility findings in OCI mode) and then
> rebuild. Steps 1 and 2a are only needed for the initial packaging run.

### Step 1: Read snap-analysis.json

Read the analysis file from `$ANALYSIS_FILE` (resolved as in the Overview: the
project-scoped `/tmp` path, or the legacy `./snap-analysis.json` fallback). All decisions
about language, plugin, confinement, interfaces, hooks, and layouts come from this file —
do not re-inspect the source code. The fields are:

| Field | Meaning |
|---|---|
| `schema_version` | `"1.0"`, `"1.1"` (may carry an `oci` block), or `"1.2"` (may carry a top-level `target_arch`) |
| `project.*` | Snap name, version, summary, description, license, grade |
| `snap.base` | Always `core24` |
| `snap.confinement` | `strict` or `classic` |
| `build.plugin` | Snapcraft plugin to use (`dump` for OCI, with a local `rootfs/` source) |
| `build.plugin_config` | Plugin-specific keys to merge into the `parts` entry |
| `build.build_packages` / `build.stage_packages` | Dependency lists |
| `build.override_build_extra` | Extra shell commands to append after `craftctl default` (null if none) |
| `apps[]` | Each app/daemon: name, command, daemon type, plugs, environment |
| `hooks[]` | Hook names to generate |
| `layouts` | Path remapping entries |
| `interfaces[].auto_connected` | Drives whether a `snap connect` command appears in SNAP_PACKAGING.md |
| `notes[]` | Caveats to surface in the chat summary and SNAP_PACKAGING.md |
| `target_arch` (top-level, general path) | Non-null triggers a `platforms:` stanza — same rendering as `oci.target_arch` below, mutually exclusive with it |

**OCI-mode detection:** if the top-level `oci` key is present, this analysis describes a
container image; switch Step 2a into **OCI rendering mode** and read these additional
fields (all produced by `snap-oci-analyzer`):

| `oci.*` field | Consumed for |
|---|---|
| `docker_to_snap_snapcraft_path` | Scaffold manifest to refine in place (Step 2a start point) |
| `rootfs_path` | The `dump`-plugin `source:` (already in `build.plugin_config`) |
| `target_arch` | The `platforms:` stanza |
| `merged_usr`, `glibc_compat` | `command:` path selection + RPATH mitigation |
| `system_usernames` | `system-usernames:` stanza + wrapper privilege-drop |
| `overrides_needed[]` | `override-build:` / `override-prime:` steps |
| `content_interfaces[]` | `slots:` / `plugs:` content-interface blocks |
| `config_options[]` | `configure`/`install` hook bodies + config-file wiring |
| `entrypoint`, `working_dir`, `env`, `exposed_ports`, `volumes`, `user` | Context/cross-checks |
| `reproducibility_baseline` | Passed through untouched — the validator reads it |

All decisions about confinement, plugin choice, interfaces, and hooks have already been made
by the analyzer and recorded in `snap-analysis.json`. Do not second-guess them.

Consult `references/snapcraft-core24-reference.md` for field syntax when translating the
analysis into YAML. `snap-validation-results.json`'s extended fields (`devmode_pass`,
`devmode_notes`, `reproducibility`, `diagnostics`) also feed Step 2b.

### Step 2a: Write Files to Disk (initial mode)

Write all files. Do not show drafts and ask for approval — write directly.

**`snap/snapcraft.yaml`**
Complete snap manifest. Use `assets/snapcraft.yaml.template` for structural reference.
Translate every field from `snap-analysis.json` — do not leave placeholder comments.

- If `build.override_build_extra` is non-null, emit an `override-build` that starts with
  `craftctl default` followed by the extra commands.
- Merge `build.plugin_config` keys directly into the part's YAML fields.
- Emit `apps[].environment` entries only when the environment map is non-empty.
- If the top-level `target_arch` field is non-null, emit the same `platforms:` stanza
  documented for OCI mode below:
  ```yaml
  platforms:
    <target_arch>:
      build-on: [<target_arch>]
      build-for: [<target_arch>]
  ```
  Omit `platforms:` entirely when `target_arch` is `null` (the common host-arch case) —
  snapcraft already defaults to the host architecture without it.

**`snap/hooks/<hook-name>`**
One shell script per hook named in `hooks[]`. Consult `references/snap-hooks-reference.md`
for the correct hook body for each type. Begin each with `#!/bin/bash` and `set -e`. Keep
hooks minimal — they run as root and must complete quickly.

**`SNAP_PACKAGING.md`**
Include:
1. Prerequisites (snapcraft install, LXD or Multipass setup)
2. Build command (`export SNAPCRAFT_BUILD_INFO=1 && snapcraft pack` from the project root)
3. Install in devmode for first test: `sudo snap install --devmode *.snap`
4. List every interface where `auto_connected: false` with the exact `snap connect` command
5. How to install with real confinement once manual devmode testing passes: `sudo snap install --dangerous *.snap`
6. How to submit to the Snap Store (optional, if the app looks store-ready)
7. Common troubleshooting (AppArmor denials via `snap run --shell`, `journalctl -xe`)
8. Any items from `notes[]` in `snap-analysis.json` that the user should be aware of
9. If `target_arch` is non-null, note the target architecture and that the `platforms:`
   stanza already pins it — no `--build-for` flag is needed on `snapcraft pack`

### Step 2a (OCI variant): OCI rendering mode

Take this path **instead of** the initial-mode Step 2a above when `snap-analysis.json`
has an `oci` key. Everything else about the pipeline (Step 3 build, Step 4 report) is
unchanged. The read-only-`rootfs/` rule from the Overview applies throughout: encode every
image change as an override step; never edit the source tree.

**1. Start from the `docker-to-snap` scaffold, not the blank template.** Read
`oci.docker_to_snap_snapcraft_path` and refine that file in place — it already encodes real
generated machinery (the wrapper script, `build_scripts/` wiring, a `/etc/hosts` install
hook) that would be costly to regenerate from facts. Do not start from
`assets/snapcraft.yaml.template` in OCI mode.

**2. Bake the target architecture into the recipe.** Write a `platforms:` stanza from
`oci.target_arch` so the build targets exactly one architecture (a single container image
is not multi-arch), rather than relying on callers to pass `--build-for`:

```yaml
platforms:
  <target_arch>:
    build-on: [<target_arch>]
    build-for: [<target_arch>]
```

**3. Render `system-usernames:` + privilege drop** from `oci.system_usernames` (when
`needed`). Add the stanza (`system-usernames: {_daemon_: shared}`) and apply the wrapper
privilege-drop for the recorded `method` (env-var/CLI-flag set to `_daemon_`, a `setpriv`
wrapper, or none for `getpwnam_hardcoded`). See `references/system-usernames-guide.md`
(rendering sections).

**4. Render `override-build:` / `override-prime:` steps** from `oci.overrides_needed[]`.
Translate each structured fact (`kind`, `target_path`, `phase`) into the concrete command
idiom using `references/override-steps-guide.md`. Apply them with `patch_snapcraft.py`
(`--override-build` / `--override-prime`, see Step 2.4). For >~3 mutations or reusable
sets, extract scripts into a `patch_scripts/` folder and call them from the override; clean
the affected part before rebuilding when a part-run script changes. **Never write to
`rootfs/`.**

**5. Render `slots:` / `plugs:` content-interface blocks** from `oci.content_interfaces[]`
using `references/content-interface-guide.md` — provider declares a `content` slot exposing
`$SNAP_COMMON/<subpath>`; consumer declares a matching `content` plug with `target:
$SNAP_COMMON/<subpath>`. Honor the **double-bind rule**: do not add a `layout:` for the same
path a content plug's `target` resolves to. Do not set `default-provider` for locally-built
snaps.

**6. Render `configure`/`install` hook bodies** from `oci.config_options[]` per the "OCI
operator-configuration hook bodies" section of `references/snap-hooks-reference.md` (built
from `assets/configure-hook-template.sh` and `assets/install-hook-additions.sh`). **Append
to** — never replace — the `docker-to-snap`-generated install hook. Add
`snapctl restart` only for daemon apps. Merge (don't replace) the generated `hooks:`
stanza. Because hooks live outside the parts system, changing them requires
`snapcraft clean --use-lxd` before the next build.

**7. Apply glibc / merged-`/usr` mitigation** from `oci.glibc_compat` / `oci.merged_usr`:
select the `command:` path (`usr/bin/…` when merged, else `bin/library_wrapper.sh`); when
`glibc_compat.mitigation == "rpath_embed"`, add an `override-build` step that invokes the
scaffold's `build_scripts/embed_rpath.sh` (generated by `docker-to-snap`, **not** shipped by
this skill — never copy it, only wire the call). **Never add `LD_LIBRARY_PATH`** to
`environment:` for a glibc mismatch — use RPATH embedding.

Then write `SNAP_PACKAGING.md` as in initial mode, additionally documenting: the target
architecture, any `snap set <key>` config options, content interfaces to connect, and
store-review-only interfaces the validator flags.

### Step 2b: Patch snapcraft.yaml (patch mode)

Read `snap-validation-results.json` and branch on the *kind* of remediation. Use
`scripts/patch_snapcraft.py` for supported app plugs, layouts, and part overrides (Step
2.4); render required top-level structures directly as part of the packager's manifest
work.

**Validation diagnostics:** If `diagnostics[]` is non-empty, do not mutate the manifest
or rebuild. Report each diagnostic and stop so the caller can resolve the pre-flight
failure (for example, build the missing `.snap` artifact) before validation is retried.

**(a) Denial → plug** (base case, all modes). For each entry in `denials[]`:
- Add `interface_suggestion` to `apps.<app>.plugs` (idempotent — never duplicate):
  `patch_snapcraft.py --app <app> --plugs <interface_suggestion>`.

**(b) Denial → layout** (when the denial is a hardcoded path, not a capability). Add a
`layout:` entry binding the path into `$SNAP`/`$SNAP_COMMON`, validated against
`patch_snapcraft.py`'s built-in layout constraints: `patch_snapcraft.py --layout /hardcoded/path
'$SNAP/hardcoded/path'`. (Representable in the schema already; now an explicit Step-2b
action.)

**(c) `devmode_pass: false` → build-correctness fix.** Can arise for any snap, OCI or
source-built. This is **not** a confinement denial — do not touch plugs/layouts. Consume
`devmode_notes[]` and fix the recipe at its root cause: for OCI-derived snaps this is
typically the interpreter-patching `override-build`, the `command:` path, or RPATH
embedding (see `references/glibc-compat-guide.md` / `override-steps-guide.md`, OCI mode);
for source-built snaps it's more often a wrong `command:` path, a missing install step, or
a build-system misconfiguration — trace the crash evidence in `devmode_notes[]` back to the
part/app definition that produced it.

**(d) `reproducibility.diffs[]` → override additions** (OCI mode). Each diff entry
(`added`/`removed`/`modified`) becomes an `oci.overrides_needed`-shaped fix rendered exactly
like Step 2a variant #4: map the delta to a deterministic `override-build`/`override-prime`
command via `references/override-steps-guide.md` and apply with `patch_snapcraft.py`.

After patching, proceed directly to **Step 3** to rebuild.

### Step 2.4: `patch_snapcraft.py` — the single manifest mutator

`scripts/patch_snapcraft.py` is the packager's **only** tool for mutating
supported incremental `apps`, `layout`, and `parts` entries in Step 2b. It is idempotent
(skips plugs/layouts/override-commands already present), `--dry-run`-capable, and writes
a `snapcraft.yaml.bak` before saving. It does not render initial manifests or named
top-level structures such as `platforms`, `hooks`, `slots`, and `plugs`. Always dry-run
first, then apply:

```bash
# Plugs + layouts (dry run, then drop --dry-run to apply)
python3 <skill-dir>/scripts/patch_snapcraft.py \
  --snapcraft snap/snapcraft.yaml --app <app> \
  --plugs network network-bind \
  --layout /var/lib/<app> '$SNAP_COMMON/<app>' --dry-run

# Override steps on a part
python3 <skill-dir>/scripts/patch_snapcraft.py \
  --snapcraft snap/snapcraft.yaml --part <part> \
  --override-build "patchelf --set-interpreter \$SNAPCRAFT_PART_INSTALL/lib/ld.so \$SNAPCRAFT_PART_INSTALL/usr/bin/<app>" \
  --override-build "chmod 755 \$SNAPCRAFT_PART_INSTALL/usr/bin/<app>"
```

Exit codes: `1` file not found · `2` app not found · `3` YAML parse error · `4` no
`--plugs`/`--layout`/`--override-build`/`--override-prime` given · `5` `--part` not found ·
`6` `--override-*` without `--part`. The `hooks:` stanza and `platforms:` stanza are not
part targets — add those directly to the YAML (the script targets apps and parts). Reserve
freehand edits for those two stanzas only.

### Step 3: Build and Verify

Run `snapcraft pack` from the project root and iterate until the build succeeds, up to **3 attempts**. Always set `SNAPCRAFT_BUILD_INFO=1` so build provenance metadata is embedded in the snap.

```bash
cd <project-root>
export SNAPCRAFT_BUILD_INFO=1
snapcraft pack 2>&1
```

**NEVER use `--destructive-mode`.** That flag builds directly on the host system, bypassing the LXD/Multipass container. It pollutes the host with build dependencies and produces artefacts that may not reproduce cleanly. Always let snapcraft use its default isolated build environment.

**If the build fails:**
1. Read the full error output carefully — snapcraft errors are usually precise about the cause.
2. Fix the issue in the relevant file (`snap/snapcraft.yaml`, a hook, or source).
3. Run `snapcraft pack` again. Repeat until the build produces a `.snap` file with no errors.

**If the error output alone isn't enough to diagnose the failure**, drop into the LXD
build instance instead of guessing: `snapcraft pack --shell-after` opens a shell after
the build steps run (inspect what actually landed in `$SNAPCRAFT_PART_INSTALL`);
`snapcraft pack --shell` opens one before they run (inspect the fetched sources/build
environment). Both work for any build, not just failures — use them whenever text
output leaves the cause ambiguous.

**When only an `override-build`/`override-prime` command or a hook script changed**,
clean just the affected part (`snapcraft clean <part> --use-lxd`) before rebuilding
instead of a full `snapcraft clean --use-lxd`. A full clean re-fetches every part's
sources and can still reuse a stale cached copy of a changed script if the part itself
isn't explicitly reset; a selective clean is faster and avoids that trap.

**Common failures and fixes:**

| Error | Fix |
|---|---|
| `cannot specify a core 'build-base' alongside a 'base'` | Remove `build-base`; it is only valid with `base: bare` |
| `layout "..." in an off-limits area` | Remove the layout; off-limits prefixes include `/var/run`, `/run`, `/proc`, `/sys`, `/dev`, `/bin`, `/sbin`, `/lib`, `/usr/bin`, `/usr/sbin`, `/usr/lib`. For pidfiles under `/var/run`, pass `--pidfile $SNAP_DATA/...` to the daemon command instead |
| `cannot find package <pkg>` in stage-packages | Check the exact package name for Ubuntu 24.04 (Noble): `apt-cache search <name>` inside an LXD container or check `packages.ubuntu.com` |
| Build tool not found (`autoreconf`, `cmake`, etc.) | Add the missing tool to `build-packages` |
| Binary not found at expected path after install | Check `make install` destination with `DESTDIR=/tmp/test make install && find /tmp/test` and adjust the `command:` path accordingly |

**Lint warnings** (do not block the build — the snap still packs):
- `title`, `contact`, `license`, `issues`, `source-code`, `website` are optional metadata; only add `license` when the app's license is unambiguous from the codebase.

### Step 4: Report

After the build succeeds, summarize in the chat:
- Files created and their locations
- Plugin choice and confinement level (sourced from `snap-analysis.json`)
- Interfaces that require manual `snap connect`
- Any notes from `snap-analysis.json` the user should act on

## Key Rules

- **Requires `snap-analysis.json`** (at `/tmp/snap-analysis-$(basename "$PWD").json`, or
  the legacy `./snap-analysis.json`) — run `snap-analyzer` (source) or `snap-oci-analyzer`
  (container) first if it is absent
- **This skill is the sole writer of `snap/snapcraft.yaml`.** Analyzers emit facts; the
  validator only reports. Use `scripts/patch_snapcraft.py` for supported incremental
  app plugs, layouts, and part overrides; render initial and named top-level structures
  directly.
- **Never write to a container `rootfs/`.** Encode every image change as an
  `override-build:`/`override-prime:` step so the recipe is self-contained and reproducible.
- **OCI mode** (analysis has an `oci` key): start from the `docker-to-snap` scaffold, add a
  `platforms:` stanza from `oci.target_arch`, and render system-usernames / overrides /
  content interfaces / config hooks from the `oci.*` facts. Never use `LD_LIBRARY_PATH` for
  a glibc mismatch — use RPATH embedding via the generated `build_scripts/embed_rpath.sh`.
- **General path cross-compilation** (top-level `target_arch` non-null): add the same
  `platforms:` stanza, keyed on `target_arch` instead of `oci.target_arch` — otherwise
  identical rendering. Omit `platforms:` when `target_arch` is `null`.
- Always set `base: core24`; do NOT set `build-base` (it is only valid with `base: bare`)
- Never use `devmode` in generated files — it is a testing-only aid
- If the app has multiple binaries or services, model each as a separate entry under `apps`
- For daemons: use `daemon: simple` (stays in foreground) or `daemon: forking` (calls fork/daemonizes)
- Layouts (`layout:`) are the right tool when an app hardcodes paths like `/etc/myapp` or `/var/lib/myapp`
- Stage packages go in `stage-packages` on the part; build-time-only packages go in `build-packages`
- **Prefer `build-packages`/`stage-packages` over `build-snaps`/`stage-snaps`** — automatic CVE reporting works correctly only when dependencies come from `stage-packages` (combined with `SNAPCRAFT_BUILD_INFO=1`). Use `build-snaps`/`stage-snaps` only when a dependency is unavailable as a Debian package or must come from a specific snap (e.g., a snap SDK or a content-sharing snap provider)

## Resources

| File | Purpose |
|---|---|
| `assets/snapcraft.yaml.template` | Structural reference for the initial (non-OCI) manifest |
| `assets/configure-hook-template.sh` | Starter `snap/hooks/configure` with validation for common option types (OCI mode) |
| `assets/install-hook-additions.sh` | Additions to merge into a `docker-to-snap` install hook for default config + initial keys (OCI mode) |
| `references/snapcraft-core24-reference.md` | core24 / snapcraft 8.x field syntax |
| `references/snap-hooks-reference.md` | Lifecycle hooks + OCI operator-configuration hook-body rendering |
| `references/snap-interfaces-catalog.md` | Interface names and AC/MC status |
| `references/override-steps-guide.md` | Map rootfs/prime mutations → `override-build`/`override-prime` (OCI mode) |
| `references/content-interface-guide.md` | Content slot/plug rendering + double-bind rule (OCI mode) |
| `references/glibc-compat-guide.md` | glibc / merged-`/usr` mitigation rendering, ELF-crash fixes (OCI mode) |
| `references/system-usernames-guide.md` | `system-usernames:` stanza + privilege-drop wrapper rendering (OCI mode) |
| `scripts/patch_snapcraft.py` | The single tool for all `snapcraft.yaml` mutations (plugs, layouts, override steps) |
