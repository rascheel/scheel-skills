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
  make a snap, write snapcraft yaml, snap containerize, generate snap files.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.1.0"
  summary: "Reads snap-analysis.json (from /tmp) and generates snapcraft.yaml, lifecycle hooks, and a packaging guide, then builds the snap."
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

Reads `snap-analysis.json` (written by the `snap-analyzer` skill) and produces:
- `snap/snapcraft.yaml` — the snap manifest (core24, snapcraft 8.x)
- `snap/hooks/<hook>` — lifecycle hooks (only those listed in the analysis)
- `SNAP_PACKAGING.md` — build instructions, interface connection commands, and testing guide

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
> `"clean": false`, skip to **Step 2b** — patch `snap/snapcraft.yaml` based on the denial
> list and then rebuild. Steps 1 and 2a are only needed for the initial packaging run.

### Step 1: Read snap-analysis.json

Read the analysis file from `$ANALYSIS_FILE` (resolved as in the Overview: the
project-scoped `/tmp` path, or the legacy `./snap-analysis.json` fallback). All decisions
about language, plugin, confinement, interfaces, hooks, and layouts come from this file —
do not re-inspect the source code. The fields are:

| Field | Meaning |
|---|---|
| `project.*` | Snap name, version, summary, description, license, grade |
| `snap.base` | Always `core24` |
| `snap.confinement` | `strict` or `classic` |
| `build.plugin` | Snapcraft plugin to use |
| `build.plugin_config` | Plugin-specific keys to merge into the `parts` entry |
| `build.build_packages` / `build.stage_packages` | Dependency lists |
| `build.override_build_extra` | Extra shell commands to append after `craftctl default` (null if none) |
| `apps[]` | Each app/daemon: name, command, daemon type, plugs, environment |
| `hooks[]` | Hook names to generate |
| `layouts` | Path remapping entries |
| `interfaces[].auto_connected` | Drives whether a `snap connect` command appears in SNAP_PACKAGING.md |
| `notes[]` | Caveats to surface in the chat summary and SNAP_PACKAGING.md |

All decisions about confinement, plugin choice, interfaces, and hooks have already been made
by the `snap-analyzer` skill and recorded in `snap-analysis.json`. Do not second-guess them.

Consult `references/snapcraft-core24-reference.md` for field syntax when translating the
analysis into YAML.

### Step 2a: Write Files to Disk (initial mode)

Write all files. Do not show drafts and ask for approval — write directly.

**`snap/snapcraft.yaml`**
Complete snap manifest. Use `assets/snapcraft.yaml.template` for structural reference.
Translate every field from `snap-analysis.json` — do not leave placeholder comments.

- If `build.override_build_extra` is non-null, emit an `override-build` that starts with
  `craftctl default` followed by the extra commands.
- Merge `build.plugin_config` keys directly into the part's YAML fields.
- Emit `apps[].environment` entries only when the environment map is non-empty.

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

### Step 2b: Patch snapcraft.yaml (patch mode)

Read `snap-validation-results.json`. For each entry in `denials[]`:

1. Open `snap/snapcraft.yaml` and locate the `apps.<app-name>` section.
2. If a `plugs:` list exists, append `interface_suggestion` (skip if already present).
3. If no `plugs:` key exists, add `plugs:` with the new plug as its first item.
4. Preserve all existing comments and formatting — this is an in-place surgical edit.
5. This operation is idempotent — never duplicate a plug already listed.

After patching, proceed directly to **Step 3** to rebuild.

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
  the legacy `./snap-analysis.json`) — run `snap-analyzer` first if it is absent
- Always set `base: core24`; do NOT set `build-base` (it is only valid with `base: bare`)
- Never use `devmode` in generated files — it is a testing-only aid
- If the app has multiple binaries or services, model each as a separate entry under `apps`
- For daemons: use `daemon: simple` (stays in foreground) or `daemon: forking` (calls fork/daemonizes)
- Layouts (`layout:`) are the right tool when an app hardcodes paths like `/etc/myapp` or `/var/lib/myapp`
- Stage packages go in `stage-packages` on the part; build-time-only packages go in `build-packages`
- **Prefer `build-packages`/`stage-packages` over `build-snaps`/`stage-snaps`** — automatic CVE reporting works correctly only when dependencies come from `stage-packages` (combined with `SNAPCRAFT_BUILD_INFO=1`). Use `build-snaps`/`stage-snaps` only when a dependency is unavailable as a Debian package or must come from a specific snap (e.g., a snap SDK or a content-sharing snap provider)
