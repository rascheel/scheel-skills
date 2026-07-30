---
name: snap-oci-analyzer
description: >
  Alternative producer of snap-analysis.json for OCI/container input: Docker Hub URLs,
  image references, `docker save` tarballs, or pre-extracted `config.json` + `rootfs/`.
  Downloads with skopeo, extracts via docker-to-snap, derives the build architecture from
  OCI metadata, and delegates binary analysis to analyze-binary-for-snapping. Emits the
  facts needed to package the image — interfaces, layouts, overrides, content interfaces,
  config options, system-usernames, glibc/merged-usr — as an `oci` block. Does NOT write
  snapcraft.yaml; it is the OCI sibling of snap-analyzer, consumed by snap-packager. WHEN:
  OCI config to snap, container to snap, config.json snap analysis, docker save tarball to
  snap, docker image to snap, snap interfaces from OCI, snap layout from rootfs, OCI
  architecture to snapcraft build-for, snap confinement from container image, convert OCI
  image to snap, analyze container for snap, docker-to-snap analysis, Docker Hub URL to
  snap, download container image for snap analysis.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.0.0"
  summary: "Analyzes OCI/Docker container input and writes snap-analysis.json (schema 1.1, with an oci block) — the packaging spec consumed by snap-packager."
  tags:
    - snap
    - snapcraft
    - oci
    - analysis
    - canonical
    - linux
---

# Snap OCI Analyzer

Analyzes an OCI/Docker container — from a Docker Hub URL, image reference, `docker save`
tarball, or a pre-extracted `config.json` + `rootfs/` — and writes a `snap-analysis.json`
that the `snap-packager` skill consumes to generate `snapcraft.yaml`, hooks, and a
packaging guide.

This skill is the **OCI-input sibling** of `snap-analyzer`. Both are alternative
producers of the *same* `snap-analysis.json` contract: `snap-orchestrator` picks
`snap-analyzer` for source-code projects and `snap-oci-analyzer` for container input.
Everything here is **analysis and fact-gathering only**.

> **This skill never writes `snapcraft.yaml`.** It records structured *facts* (plugs,
> layouts, override steps, content interfaces, config options, arch, glibc/user facts)
> in `snap-analysis.json`. Turning those facts into YAML — and every mutation of
> `snapcraft.yaml` — is exclusively the `snap-packager` skill's job. In particular:
> record what `docker-to-snap` scaffolds as *paths and facts*; do not treat the scaffold
> as the final recipe, and do not patch it here.

> **`rootfs/` is a read-only source artifact.** Never write to, patch, chmod, delete,
> or rewrite anything inside `rootfs/`. When the image needs a change to build/install/run
> correctly (ELF-interpreter patching, symlink fixes, config edits), *record* it as an
> `oci.overrides_needed[]` fact so the packager can encode it as an `override-build:` /
> `override-prime:` step. This keeps the final recipe self-contained and reproducible.

> **Where the file goes:** write to a project-scoped path under `/tmp`, not the project
> root — it is a transient hand-off artifact. Compute it once and reuse it (the
> `snap-packager` skill reads the same path):
>
> ```bash
> ANALYSIS_FILE="/tmp/snap-analysis-$(basename "$PWD").json"
> ```

Work through the phases in order.

---

## Phase 0 — Detect input type

Determine what the user has provided:

```bash
# Check for pre-extracted OCI artifacts
ls config.json rootfs/ 2>/dev/null

# Check for a tarball
ls *.tar 2>/dev/null
```

- **`config.json` and `rootfs/` exist** → skip Phase 0b and 0c, go to Phase 0d.
- **A Docker Hub URL or image reference was provided** (e.g.
  `https://hub.docker.com/_/nginx`, `nginx:1.27`, `quay.io/org/app:tag`) → run Phase 0b
  to download it as a docker-archive tarball, then Phase 0c.
- **A `.tar` file was provided** (docker-archive/OCI-archive from `docker save`) → skip
  0b, go to Phase 0c.
- **Neither** → ask the user for a Docker Hub URL / image reference, a `docker save`
  `.tar` path, or a directory with `config.json` + `rootfs/`.

---

## Phase 0a — Ensure local dependencies are installed

Run the dependency helper before invoking local scripts or `docker-to-snap`. It checks
for `tar`, `skopeo`, `umoci`, `jq`, and the Python YAML library.

```bash
python3 <skill-dir>/scripts/ensure_dependencies.py --install -y
```

Exit codes: `0` present/installed; `1` missing and `--install` not passed; `2` install
failed or non-apt system; `3` installed but commands/modules still missing. On any
non-zero exit, report the exact stderr and stop — do not extract until dependencies are
available.

---

## Phase 0b — Download image link/reference to tarball

> **Only if Phase 0 determined the input is a Docker Hub URL or image reference.**

```bash
python3 <skill-dir>/scripts/download_image.py \
  "https://hub.docker.com/r/library/nginx" \
  --output nginx_latest.tar
```

The script normalizes Docker Hub links to pullable references, defaults missing tags to
`latest`, and writes a local `docker-archive` tarball (no local Docker daemon needed).
For private/rate-limited images, `skopeo login <registry>` first, then rerun. Record the
printed tarball path as the Phase 0c `--tarball` input **and** as
`oci.reproducibility_baseline.tarball_path` (needed later for the validator's
reproducibility check).

---

## Phase 0c — Extract tarball with docker-to-snap

> **Only if Phase 0 found a `.tar` file or Phase 0b created one.**

Read `references/docker-to-snap-options.md` for the full options, defaults, and
filename-inference rules.

**Gather required information** (do not assume required values):

- **`--application-name`** / **`--application-version`**: `--application-name` is the
  full, unitary snap name — infer it from a `<name>_<version>.tar` filename and confirm;
  otherwise ask. Infer `--application-version` the same way (version default `0.1`).
- **`--output-folder`**, **`--service-name`**, **`--envvars`**: optional; prompt once.
- **`--do-not-daemonize`**: **classify, don't blindly ask.** Long-lived
  server/listener/broker/scheduler/pipeline-stage → daemon (omit the flag). A
  run-to-completion CLI/batch/converter/report tool → not a daemon (pass the flag; a
  daemon that exits immediately looks like a crash-loop to systemd). Use the image
  name/purpose, the user's description, upstream docs, and whether the entrypoint blocks.
  Re-check `process.args[0]` after Phase 1 and, if it contradicts the choice, re-run
  `docker-to-snap` with the corrected flag. **This classification determines
  `apps[].daemon` in the output** (see Phase 5). State your reasoning to the user; only
  ask if genuinely ambiguous.

**Run docker-to-snap** — always include `--suppress-build` (the pipeline builds later via
`snap-packager` / `snap-validator`):

```bash
./docker-to-snap \
  --tarball <path-to-tar> \
  [--application-name <name>] \
  [--application-version <version>] \
  [--output-folder <folder>] \
  [--service-name <name>] \
  [--do-not-daemonize] \
  [--envvars <file>] \
  --suppress-build
```

If `docker-to-snap` reports missing tools, run `ensure_dependencies.py --install -y` once
and retry; if it still fails, report the exact stderr and stop. On success, `cd` into the
output folder.

**Record the exact invocation** (command + flags) as
`oci.reproducibility_baseline.extraction_command_recorded` — the validator replays it
verbatim to prove the recipe reproduces from a clean extraction.

---

## Phase 0d — Locate target files

```bash
ls config.json rootfs/ 2>/dev/null
ls snapcraft.yaml snap/snapcraft.yaml 2>/dev/null
```

Record as facts (for the `oci` block): `config.json` path (`oci.config_json_path`),
`rootfs/` path (`oci.rootfs_path`), the `docker-to-snap` output dir
(`oci.docker_to_snap_output_dir`), and the scaffold snapcraft path
(`oci.docker_to_snap_snapcraft_path`) — the packager *starts from* that scaffold rather
than a blank template. Also record app name(s) under `apps:` in the scaffold.

**Verify `build_scripts/` was populated** by the generator (the packager wires these into
`override-build`; this skill only confirms they exist):

```bash
ls -1 build_scripts/*.sh 2>/dev/null || echo "WARNING: build_scripts/ not populated"
```

Expected: `create_wrapper.sh`, `embed_rpath.sh`, `patch_interpreter.sh`,
`replace_absolute_symlinks.sh`. If missing, verify the generator's build-scripts source
directory and re-run `docker-to-snap`. These scripts are **generated at extraction time,
not shipped by any skill** — never copy them; the packager only invokes them.

---

## Phase 1 — Parse OCI context

Read `config.json` and extract:

1. `process.args[0]` (main executable path) → `oci.entrypoint`
2. `process.capabilities` (all five sets) — feeds interface inference (Phase 2)
3. `mounts` — feeds interface/layout inference
4. OCI image architecture metadata → `oci.target_arch` (Phase 1.1)
5. `process.user` (uid, gid, username) → `oci.user`; also `working_dir`,
   `exposed_ports`, `env`, `volumes` for the `oci` block

Resolve the executable under `rootfs/` using `process.args[0]`.

### 1.1 — Derive the required snap build architecture

Derive `target_arch` from container metadata; the packager bakes it into a `platforms:`
stanza so the build targets exactly one architecture. Normalize OCI/Go arch names to
Snapcraft/Debian names with this table (used verbatim):

| OCI metadata value | `target_arch` |
|---|---|
| `amd64`, `x86_64` | `amd64` |
| `arm64`, `aarch64` | `arm64` |
| `arm`, `arm/v7`, `arm/v6`, `armhf` | `armhf` |
| `386`, `i386` | `i386` |
| `ppc64le` | `ppc64el` |
| `s390x` | `s390x` |
| `riscv64` | `riscv64` |

```bash
python3 - <<'PY'
import json

c = json.load(open("config.json"))
annotations = c.get("annotations", {})
raw_arch = (
    annotations.get("org.opencontainers.image.architecture")
    or annotations.get("io.containerd.image.architecture")
    or c.get("architecture")
    or c.get("Architecture")
)
variant = (
    annotations.get("org.opencontainers.image.variant")
    or c.get("variant")
    or c.get("Variant")
)
if raw_arch == "arm" and variant:
    raw_arch = f"arm/{variant}"

mapping = {
    "amd64": "amd64",
    "x86_64": "amd64",
    "arm64": "arm64",
    "aarch64": "arm64",
    "arm": "armhf",
    "arm/v7": "armhf",
    "arm/v6": "armhf",
    "armhf": "armhf",
    "386": "i386",
    "i386": "i386",
    "ppc64le": "ppc64el",
    "s390x": "s390x",
    "riscv64": "riscv64",
}
target_arch = mapping.get(str(raw_arch).lower()) if raw_arch else None
if not target_arch:
    raise SystemExit(f"Cannot determine supported architecture from OCI metadata: {raw_arch!r}")
print(target_arch)
PY
```

Record the printed value as `oci.target_arch`. If it cannot be determined, stop and
report the missing/unsupported metadata — do not emit an analysis the packager cannot
build.

```bash
python3 -c "
import json
c = json.load(open('config.json'))
p = c.get('process', {})
print('args:', p.get('args'))
print('user:', p.get('user', {}))
print('caps:', list(p.get('capabilities', {}).keys()))
print('arch:', c.get('annotations', {}).get('org.opencontainers.image.architecture') or c.get('architecture') or c.get('Architecture'))
"
```

---

## Phase 1b — Non-root user detection

> **Only if `process.user.uid` ≠ 0 (or `username` is a non-root value).** Skip for root.

Read the **detection** sections of `references/system-usernames-guide.md`. Inside a snap,
daemons start as root; a non-root OCI user means privilege separation is needed via the
`system-usernames` feature. **Detect and record only** — the packager renders the
`system-usernames:` stanza and any wrapper privilege-drop.

Run the configurability-detection commands (`references/system-usernames-guide.md §3`) to
determine how the user is set, and record `oci.system_usernames`:

| Configurability signal | `method` |
|---|---|
| User set via env var or config file | `env_var` |
| User set via CLI flag | `cli_flag` |
| User hardcoded / binary calls `setuid()` itself | `setpriv_wrapper` |
| Binary calls `getpwnam()` + `setuid()` with the configured name | `getpwnam_hardcoded` |

Set `oci.system_usernames.needed = true`, the `method`, and any `details` (var/flag/key
name) the packager needs. Do **not** edit YAML or wrapper scripts here.

---

## Phase 1c — Merged-/usr and glibc detection

> **Always run before Phase 2.** Read the **detection** sections of
> `references/glibc-compat-guide.md`. Detect and record only — the *fixes*
> (command-path selection, RPATH embedding) are the packager's job.

- **Merged-/usr:** `[ -L rootfs/bin ]`. If merged, record `oci.merged_usr = true` (the
  packager will use `usr/bin/` command paths and watch for stage collisions). If split
  (`false` — Alpine, RHEL, etc.), the generator emits a `bin/library_wrapper.sh` command
  path; note this fact.
- **glibc:** compare OCI vs base-snap glibc versions and record `oci.glibc_compat`
  (`oci_glibc_version`, `base_snap_glibc_version`, `compatible`). If they differ, set
  `mitigation = "rpath_embed"` (never `LD_LIBRARY_PATH`); otherwise `mitigation = "none"`.
  The packager wires the generated `build_scripts/embed_rpath.sh` into `override-build`.

---

## Phase 2 — Delegate binary analysis

Invoke the `analyze-binary-for-snapping` skill and pass: the resolved binary path,
`config.json` path, app name (if known), and an optional runtime command for `strace`.

> **Take Steps 1–6 (inference) only.** Instruct `analyze-binary-for-snapping` to produce
> output and **skip its Step 7** (snapcraft.yaml patching) — this skill never writes YAML.
> Its Step 7 patcher role is superseded by `snap-packager`.

Collect from the delegated output, to record as facts:

1. **Plugs to use** → `interfaces[]` / `apps[].plugs`
2. **Layouts to add** → `layouts{}`
3. **Paths that could not be mapped** → `notes[]` (unmappable, with reason)
4. **Suggested next steps** → `notes[]`
5. **Wrapper script hints** → `oci.overrides_needed[]` or `notes[]` as appropriate

Do not re-run capability/mount/binary/path analysis when delegated output is available.

---

## Phase 3 — Fallback analysis (only if delegation is unavailable)

Run local analysis only if `analyze-binary-for-snapping` cannot be used. Use
`references/capability-interface-map.md`, `references/mount-snap-map.md`,
`references/analysis-checklist.md`, and `references/layout-constraints.md`. Produce the
same facts (plugs, layouts, unmappable paths) as Phase 2.

---

## Phase 4 — Discovery of packager-facing facts

The monolithic OCI skill's "apply to snapcraft.yaml" phase is split here into
**discovery only**; the packager does the rendering. Gather these three fact sets.

### 4a — Override-step discovery (`oci.overrides_needed[]`)

Read the **inventory** guidance in `references/override-steps-guide.md`. Enumerate every
change the image needs to build/install/run correctly that must NOT be applied to
`rootfs/` directly — ELF-interpreter patching, symlink fixes, `chmod`, config edits,
file injection, deletions. For each, record a fact:

```json
{ "part": "<part>", "phase": "build | prime",
  "kind": "patch_interpreter | symlink_fix | chmod | config_edit | file_inject | custom",
  "target_path": "<path inside rootfs>", "description": "<why it is needed>" }
```

Record *what* changes and *why*; the exact override command is the packager's rendering
decision. (The validator's reproducibility phase later feeds more of these back through
the packager.)

### 4b — Content-interface discovery (`oci.content_interfaces[]`)

> **Only if two or more snaps must share a writable directory** (e.g. a cert manager
> writing certs a web server reads). Skip for single-snap deployments.

Read `references/*` content-sharing guidance. From Docker Compose volumes (or equivalent)
determine which snap **owns/writes** (provider/slot) and which **read/write**
(consumer/plug) each shared directory, and the classic path each app expects. Record one
fact per role:

```json
{ "role": "provider | consumer", "slot_or_plug_name": "<name>",
  "content_label": "<label>", "path": "$SNAP_COMMON/<subpath>",
  "snap_name_hint": "<name>" }
```

Note the "don't lay out the same path a content plug targets" rule in `notes[]` so the
packager honors it. Slot/plug YAML is the packager's job.

### 4c — Operator-config discovery (`oci.config_options[]`)

Read the **option-identification** sections of `references/snap-config-guide.md`.
Determine which application options operators legitimately need to tune (ports, log
levels, worker counts, TLS paths) from: the Docker Hub / upstream docs,
`config.json → process.env` (skip internal `PATH`/`HOME`/`TERM`/locale), config files
under `rootfs/etc/`, and caller instructions. Do **not** expose internal paths, data
directories (always `$SNAP_COMMON`), or debug flags.

For each exposed option record a fact (naming convention per the guide):

```json
{ "key": "<snap-config-key>", "source": "env_var | config_file | cli_flag",
  "source_name": "<var/key/flag name>",
  "type": "port | enum | integer | path | string", "allowed_values": ["<if enum>"],
  "default": "<value>", "config_file_format": "ini | yaml | json | env | null",
  "config_file_path": "$SNAP_COMMON/... or null",
  "wiring": "cli_flag | env_var | layout" }
```

The `configure`/`install` hook *bodies* and config-file wiring are rendered by the
packager from these facts.

---

## Phase 5 — Write snap-analysis.json

Write to `$ANALYSIS_FILE` (`/tmp/snap-analysis-$(basename "$PWD").json`), **not** the
project root. Reuse the existing schema fields exactly as `snap-analyzer` does, and add
the new optional top-level `oci` block. Set `schema_version` to `"1.1"`.

**Reused fields, OCI specifics:**
- `snap.base = "core24"`; `snap.confinement = "strict"` (classic must never be used for
  OCI — if the user insists, follow `snap-analyzer`'s classic caveat flow).
- `build.plugin = "dump"`, `build.plugin_config = {"source": "<rootfs_path>",
  "source-type": "local"}` — no new build field needed.
- `apps[].command` → the `docker-to-snap`-generated wrapper (e.g. `bin/library_wrapper.sh`
  or a `usr/bin/` path per Phase 1c).
- `apps[].daemon` → `null` for run-to-completion apps, `"simple"`/`"forking"` for daemons,
  per the Phase 0c classification.
- `hooks[]` → include `install`/`configure` when Phase 4c yields config options or the
  generator produced an `/etc/hosts` install hook.
- `interfaces[]`, `layouts{}`, `notes[]` → as gathered in Phases 2–4.

```json
{
  "schema_version": "1.1",
  "project": { "name": "...", "version": "...", "summary": "...", "description": "...", "license": null, "grade": "stable | devel" },
  "snap": { "base": "core24", "confinement": "strict", "classic_reason": null },
  "build": { "plugin": "dump", "plugin_config": { "source": "<rootfs_path>", "source-type": "local" }, "build_packages": [], "stage_packages": [], "override_build_extra": null },
  "apps": [ { "name": "...", "command": "<wrapper path>", "daemon": null, "plugs": ["..."], "environment": {} } ],
  "hooks": [],
  "layouts": { "<snap-path>": { "bind": "<snap-variable-path>" } },
  "interfaces": [ { "name": "...", "apps": ["..."], "auto_connected": true, "reason": "..." } ],
  "notes": [],

  "oci": {
    "image_ref": "<pullable reference or tarball path>",
    "digest": "<sha256:... or null>",
    "config_json_path": "<path to extracted config.json>",
    "rootfs_path": "<path to extracted rootfs/>",
    "docker_to_snap_output_dir": "<output folder docker-to-snap produced>",
    "docker_to_snap_snapcraft_path": "<scaffold snapcraft.yaml path for packager to start from>",
    "target_arch": "amd64 | arm64 | armhf | i386 | ppc64el | s390x | riscv64",
    "entrypoint": ["<process.args from config.json>"],
    "working_dir": "<string or null>",
    "exposed_ports": ["<port/proto>"],
    "env": { "<KEY>": "<value>" },
    "volumes": ["<mount path>"],
    "user": { "uid": 0, "gid": 0, "username": "<string or null>", "is_root": true },
    "merged_usr": true,
    "glibc_compat": { "oci_glibc_version": "<string or null>", "base_snap_glibc_version": "<string or null>", "compatible": true, "mitigation": "rpath_embed | none" },
    "system_usernames": { "needed": false, "method": "env_var | cli_flag | setpriv_wrapper | getpwnam_hardcoded | null", "details": {} },
    "overrides_needed": [ { "part": "<part>", "phase": "build | prime", "kind": "patch_interpreter | symlink_fix | chmod | config_edit | file_inject | custom", "target_path": "<path inside rootfs>", "description": "<why>" } ],
    "content_interfaces": [ { "role": "provider | consumer", "slot_or_plug_name": "<name>", "content_label": "<label>", "path": "$SNAP_COMMON/<subpath>", "snap_name_hint": "<name>" } ],
    "config_options": [ { "key": "<snap-config-key>", "source": "env_var | config_file | cli_flag", "source_name": "<name>", "type": "port | enum | integer | path | string", "allowed_values": [], "default": "<value>", "config_file_format": "ini | yaml | json | env | null", "config_file_path": "$SNAP_COMMON/... or null", "wiring": "cli_flag | env_var | layout" } ],
    "reproducibility_baseline": { "tarball_path": "<path to reuse for re-extraction>", "extraction_command_recorded": "<docker-to-snap invocation used, for exact replay>" }
  }
}
```

**Field rules:**
- Emit only the `oci` sub-keys that apply; use `null`/empty arrays where a section did not
  run (e.g. no non-root user → `system_usernames.needed = false`).
- `oci.reproducibility_baseline` must always be populated — the validator's
  reproducibility phase depends on the recorded tarball path and extraction command.
- Never populate anything that would require writing `snapcraft.yaml` — those are facts,
  not YAML.

---

## Phase 6 — Report

After writing the analysis, summarize in the chat (state the full `/tmp` path):

- **Input type** detected and the image/tarball used
- **Target architecture** (OCI metadata value → normalized `target_arch`)
- **Confinement** (strict) and the wrapper/command path chosen (merged vs split `/usr`)
- **Interfaces** listed — which auto-connect and which need `snap connect`
- **Overrides needed** (count and kinds), **content interfaces**, **config options**,
  and any **non-root user / glibc** facts
- **Unmappable paths** and any assumptions recorded in `notes[]`

Do **not** generate `snapcraft.yaml` or any snap artifact — that is the `snap-packager`
skill's responsibility.

---

## Resources

| File | Purpose |
|---|---|
| `references/docker-to-snap-options.md` | Options, defaults, filename-inference, examples for Phase 0c extraction |
| `references/glibc-compat-guide.md` | Merged-/usr + glibc detection (Phase 1c) |
| `references/system-usernames-guide.md` | Non-root user detection / configurability (Phase 1b) |
| `references/snap-config-guide.md` | Identifying configurable options (Phase 4c) |
| `references/capability-interface-map.md` | Fallback capability → interface mapping (Phase 3) |
| `references/mount-snap-map.md` | Fallback mount mapping (Phase 3) |
| `references/analysis-checklist.md` | Fallback binary/rootfs analysis checklist (Phase 3) |
| `references/layout-constraints.md` | Validate layout targets (Phases 2–4) |
| `references/override-steps-guide.md` | Inventory rootfs mutations for `oci.overrides_needed[]` (Phase 4a) |
| `scripts/ensure_dependencies.py` | Checks/installs local tool + Python dependencies |
| `scripts/download_image.py` | Downloads Docker Hub URLs / image references as docker-archive tarballs |
| Skill: `analyze-binary-for-snapping` | Primary analysis path for plugs/layouts/unmappable paths (Steps 1–6 only) |
