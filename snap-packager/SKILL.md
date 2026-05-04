---
name: snap-packager
description: >
  Analyzes an existing application codebase and generates all files needed to package it as a
  snap, including snapcraft.yaml targeting core24 and snapcraft 8.x, lifecycle hooks, and
  interface declarations. Writes output files directly to disk and produces a SNAP_PACKAGING.md
  guide documenting how to build, install, and test the snap and which connectors must be enabled.
  Uses snap language plugins (go, python, npm, cmake, meson) when they fit, the nil plugin for
  custom builds, and dump for file-only snaps.
  WHEN: package as snap, create snapcraft.yaml, snap this application, snap packaging,
  convert to snap, create snap, add snap support, snap confinement, snapcraft configuration,
  snap interfaces, snap hooks, snap build, package with snapcraft, core24 snap, snapcraft 8,
  make a snap, write snapcraft yaml, snap containerize.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.0.0"
  summary: "Generates snapcraft.yaml, lifecycle hooks, and a packaging guide for any app, targeting core24/snapcraft 8.x."
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

Analyzes a codebase and writes everything needed to package it as a snap:
- `snap/snapcraft.yaml` — the snap manifest (core24, snapcraft 8.x)
- `snap/hooks/<hook>` — lifecycle hooks (only when the app has real lifecycle requirements)
- `SNAP_PACKAGING.md` — build instructions, interface connection commands, and testing guide

## Workflow

### Step 1: Analyze the Codebase

Read `references/analysis-checklist.md` and work through it systematically. Do not ask the user for information that can be inferred from files — inspect `Makefile`, `go.mod`, `package.json`, `*.service` files, source imports, and README before asking anything.

Record findings for each section of the checklist:
- Language/runtime and build system
- Entry points (binary names, scripts, services)
- App type: daemon, desktop GUI, CLI, or multiple
- System resources accessed (network, filesystem, devices, audio, D-Bus, etc.)

### Step 2: Plan the Snap

**Confinement:** Default to `strict`. Use `classic` only when the app fundamentally cannot work without unrestricted filesystem access (e.g., a shell, developer toolchain, or IDE). Never use `devmode` in final output files — it is a testing-only aid.

**Grade:** Use `stable` for production-ready apps, `devel` for work-in-progress.

**Plugin strategy:**
- **Use language-specific plugins** (`go`, `python`, `npm`, `cmake`, `meson`, `rust`, etc.) when the project's build fits the plugin's expected shape — they handle toolchain setup, environment, and install paths for you with less yaml. When extra steps are needed after the plugin's normal build (e.g. fetching assets, compiling grammars, copying a runtime directory), add `override-build` that calls `craftctl default` first and then appends the extra steps — do not switch to `nil` just because there are post-build steps.
- **Use `nil` with `override-build`** when the build is reasonably custom: the core build itself doesn't fit the plugin (e.g. a vendored toolchain, a multi-stage pipeline the plugin can't model, or a non-standard build system). Don't fight a plugin to make it fit — explicit shell in `override-build` is fine.
- **Use `dump`** for apps that only need files copied into the snap (pre-built binaries, scripts).
- When using `nil`, write explicit shell commands in `override-build` so the build is transparent and auditable.

Consult `references/snapcraft-core24-reference.md` for field reference and plugin syntax.

### Step 3: Map Interfaces

For each system resource identified in Step 1, find the corresponding snap interface.

Consult `references/snap-interfaces-catalog.md`. For each interface:
- Add it to the relevant `apps` entry under `plugs` (or top-level `plugs` if shared across apps)
- Note whether it is auto-connected or requires a manual `snap connect` — this drives the packaging guide

### Step 4: Determine Hooks

Consult `references/snap-hooks-reference.md`. Add hooks only when genuinely needed:
- `install` — first-run setup (create dirs, write initial config, set defaults)
- `configure` — respond to `snap set` option changes
- `connect-plug-*` / `disconnect-plug-*` — react to interface connect/disconnect events
- `pre-refresh` / `post-refresh` — handle state migration around snap updates

### Step 5: Write Files to Disk

Write all files. Do not show drafts and ask for approval — write directly.

**`snap/snapcraft.yaml`**
Complete snap manifest. Use `assets/snapcraft.yaml.template` for structural reference. Fill every field based on actual analysis — do not leave placeholder comments.

**`snap/hooks/<hook-name>`**
One shell script per required hook. Begin each with `#!/bin/bash` and `set -e`. Keep hooks minimal — they run as root and must complete quickly.

**`SNAP_PACKAGING.md`**
Include:
1. Prerequisites (snapcraft install, LXD or Multipass setup)
2. Build command (`export SNAPCRAFT_BUILD_INFO=1 && snapcraft pack` from the project root)
3. Install in devmode for first test: `sudo snap install --devmode *.snap`
4. List every interface that requires manual connection with the exact `snap connect` command
5. How to switch to strict mode once interfaces are verified
6. How to submit to the Snap Store (optional, if the app looks store-ready)
7. Common troubleshooting (AppArmor denials via `snap run --shell`, `journalctl -xe`)

### Step 6: Build and Verify

Run `snapcraft pack` from the project root and iterate until the build succeeds. Always set `SNAPCRAFT_BUILD_INFO=1` so build provenance metadata is embedded in the snap.

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

### Step 7: Report

After the build succeeds, summarize in the chat:
- Files created and their locations
- Key decisions made (plugin choice, confinement level, interfaces selected) and why
- Interfaces that require manual `snap connect` and why they are not auto-connected
- Any assumptions made that the user should verify before building

## Key Rules

- Always set `base: core24`; do NOT set `build-base` (it is only valid with `base: bare`)
- Use language plugins (`go`, `python`, `npm`, `cmake`, `meson`, etc.) when the build fits them; reach for `nil` with `override-build` when the build is custom; use `dump` for file-copy-only snaps
- Set `confinement: strict` by default
- If the app has multiple binaries or services, model each as a separate entry under `apps`
- For daemons: use `daemon: simple` (stays in foreground) or `daemon: forking` (calls fork/daemonizes)
- Layouts (`layout:`) are the right tool when an app hardcodes paths like `/etc/myapp` or `/var/lib/myapp`
- Stage packages go in `stage-packages` on the part; build-time-only packages go in `build-packages`
- **Prefer `build-packages`/`stage-packages` over `build-snaps`/`stage-snaps`** — automatic CVE reporting works correctly only when dependencies come from `stage-packages` (combined with `SNAPCRAFT_BUILD_INFO=1`). Use `build-snaps`/`stage-snaps` only when a dependency is unavailable as a Debian package or must come from a specific snap (e.g., a snap SDK or a content-sharing snap provider)
