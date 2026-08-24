---
name: snap-orchestrator
description: >
  Coordinates snap-analyzer, snap-packager, and snap-validator as sequential
  sub-agents to take a project from source code to a validated, installable snap with correct
  interfaces. Manages the full pipeline: analyze → package → validate → patch → rebuild,
  looping the validate/patch/rebuild cycle until the snap runs clean or a maximum iteration
  limit is reached. Each sub-agent runs in its own focused context to minimize token usage.
  It selects snap-analyzer for source-code projects and snap-oci-analyzer for OCI/Docker
  container input, and drives the same package → validate → patch loop for both.
  WHEN: full snap pipeline, snap from scratch, end-to-end snap packaging, snap build and
  validate, snap orchestrate, build and test snap, snap pipeline, automate snap packaging,
  snap workflow, package and validate snap, OCI container to snap pipeline, docker image to
  snap pipeline, container to snap end-to-end.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.2.0"
  summary: "End-to-end snap pipeline for source-code or OCI/container input: delegates analysis, packaging, validation, and iterative patching to focused sub-agents."
  tags:
    - snap
    - snapcraft
    - orchestration
    - canonical
    - linux
    - pipeline
---

# Snap Orchestrator

Runs the full snap packaging pipeline by delegating each phase to a focused sub-agent.
Each sub-agent works with minimal context, communicates through files on disk, and exits
when its phase is done. The orchestrator manages control flow and the patch loop.

---

## File Contracts

The sub-agents communicate exclusively through these files. `snap-analysis.json` is a
transient hand-off artifact and lives under `/tmp` (project-scoped:
`/tmp/snap-analysis-$(basename "$PWD").json`); the rest live in the project root. Both JSON
files are at **schema `1.1`** — additive over `1.0` (new optional fields only), so a `1.0`
producer/consumer still interoperates.

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `/tmp/snap-analysis-<dir>.json` | snap-analyzer **or** snap-oci-analyzer | snap-packager, snap-validator | Full packaging specification (transient); an `oci` key marks container input |
| `snap/snapcraft.yaml` | snap-packager | snap-validator, snap-packager (patch) | Snap manifest (packager is the sole writer) |
| `snap-validation-results.json` | snap-validator | snap-packager (patch), orchestrator | Denial report + diagnostics + (OCI) devmode / store-review / reproducibility findings |

> **Input type.** Exactly one analyzer runs per pipeline: `snap-analyzer` for source-code
> projects, `snap-oci-analyzer` for OCI/container input (Docker Hub URL, image reference,
> `docker save` tarball, or pre-extracted `config.json`+`rootfs/`). Both emit the same
> `snap-analysis.json` contract; container input adds an `oci` block. Phase 0 selects; every
> later phase is producer-agnostic.

---

## Phase 0: Pre-flight

Before delegating anything, verify prerequisites directly:

```bash
lxc --version       # LXD required for validation
snapcraft --version # snapcraft required for packaging
ls                  # confirm project root is not empty
```

| Check | Failure action |
|---|---|
| `lxc` not found | Stop: "LXD is required. Install with: `snap install lxd && lxd init --auto`" |
| `snapcraft` not found | Stop: "snapcraft is required. Install with: `snap install snapcraft`" |
| Working directory empty | Stop: "No source files found. Run from the project root." |

### 0.1 Detect input type

Decide which analyzer Phase 1 delegates to:

```bash
ls config.json rootfs/ 2>/dev/null   # pre-extracted OCI artifacts
ls *.tar 2>/dev/null                  # docker save tarball
```

- **`config.json` + `rootfs/` present**, **a `*.tar` present**, or **the user's request
  names a Docker Hub URL / image reference** (e.g. `nginx:1.27`, `quay.io/org/app:tag`,
  `https://hub.docker.com/_/nginx`) → **OCI path** (`snap-oci-analyzer`).
- **Otherwise** (a source-code project) → **source path** (`snap-analyzer`).
- **Ambiguous** (both source files and an image reference, or neither) → ask the user which
  they want to package.

### 0.2 OCI dependency check (OCI path only)

Only when the OCI path is selected, verify the container tooling up front (the analyzer
re-checks and can install, but failing fast here is cheaper):

```bash
for t in skopeo umoci jq; do command -v "$t" >/dev/null || echo "missing: $t"; done
```

If any are missing, note that `snap-oci-analyzer`'s Phase 0a
(`ensure_dependencies.py --install -y`) will attempt to install them; stop only if that
later fails.

### 0.3 Resolve the analysis path

Resolve the analysis path once and reuse it for every phase:

```bash
ANALYSIS_FILE="/tmp/snap-analysis-$(basename "$PWD").json"
```

If `$ANALYSIS_FILE` already exists (or a legacy `./snap-analysis.json`), ask the user
whether to reuse it or regenerate. If `snap-validation-results.json` already exists,
delete it before starting:

```bash
rm -f snap-validation-results.json
```

---

## Phase 1: Analysis

**Delegate to: `snap-analyzer` (source path) or `snap-oci-analyzer` (OCI path)** — chosen
by Phase 0.1.

Provide this context to the sub-agent:
- Run from the current working directory (project root)
- Goal: write the analysis to `$ANALYSIS_FILE` (`/tmp/snap-analysis-$(basename "$PWD").json`)
- **OCI path:** also pass the input (Docker Hub URL / image reference / tarball path, or
  the pre-extracted `config.json`+`rootfs/`) so the analyzer can download/extract.

Wait until `$ANALYSIS_FILE` is present and contains valid JSON before continuing. The
`snap-oci-analyzer` output additionally carries an `oci` block (schema `1.1`); the
`snap-analyzer` output does not — every later phase treats both uniformly.

If `$ANALYSIS_FILE` reports `"confinement": "classic"`, the user has already been
prompted and confirmed classic confinement during the analysis phase. Skip the validation
and patch loop (Phase 3) — validation does not apply to classic snaps — and proceed directly
to the **Final Report (Phase 4)**, noting the skip and reminding the user of the Store
approval requirement and Ubuntu Core incompatibility. (OCI analyses should be `strict`;
classic is a source-path edge case.)

---

## Phase 2: Initial Packaging

**Delegate to: `snap-packager`**

Provide this context to the sub-agent:
- The analysis is at `$ANALYSIS_FILE` (`/tmp/snap-analysis-$(basename "$PWD").json`)
- No `snap-validation-results.json` is present (initial packaging mode — Step 2a)
- Goal: write `snap/snapcraft.yaml`, `snap/hooks/*`, `SNAP_PACKAGING.md`, and produce a
  built `.snap` file in the project root

No orchestrator-level branch is needed here: `snap-packager` self-detects the `oci` key and
takes its OCI rendering path (Step 2a variant) or the source path automatically.

Wait until a `.snap` file exists in the project root before continuing.

---

## Phase 3: Validation & Patch Loop

Three independently-capped counters run in this phase; track each separately:

| Counter | Cap | Trigger |
|---|---|---|
| Denial-patch iterations | **5** | `clean: false` with denials |
| Devmode build-fix iterations (OCI) | **3** | `devmode_pass: false` |
| Reproducibility iterations (OCI, Phase 3.5) | **3** | non-empty `reproducibility.diffs[]` |

### 3.1 Delete previous results

```bash
rm -f snap-validation-results.json
```

### 3.2 Delegate to: `snap-validator`

Provide this context to the sub-agent:
- The `.snap` file in the project root is the target
- `snap/snapcraft.yaml` is available for reference
- **`$ANALYSIS_FILE` is available** (`/tmp/snap-analysis-$(basename "$PWD").json`) — pass it
  so the validator can detect OCI mode (its `oci` key) and read `oci.target_arch` /
  `oci.reproducibility_baseline`
- Goal: run all apps and daemons in a clean LXD container, capture any AppArmor/SecComp
  denials, and write `snap-validation-results.json`

Wait until `snap-validation-results.json` is present before continuing.

### 3.3 Check results

Read `snap-validation-results.json`, and branch on the *kind* of result:

1. **`diagnostics[]` is non-empty** → stop and report the diagnostics. These are validation
   pre-flight failures (for example, a missing `.snap`), not denial-patch candidates.
2. **`devmode_pass == false`** (OCI mode) → this is a **build-correctness** failure, not a
   denial. If the devmode build-fix counter < 3, delegate to `snap-packager`'s **build-fix
   branch** (Step 2b case (c) — consumes `devmode_notes[]`, does **not** touch
   plugs/layouts), rebuild, increment the devmode counter, and return to **Step 3.1**. If
   the counter = 3, exit the loop to Phase 4 and report the devmode failure separately (do
   **not** count these against the 5-iteration denial cap).
3. **`clean == true`** → the denial loop is done. If OCI mode, go to **Phase 3.5**
   (reproducibility); otherwise go to **Phase 4**.
4. **`clean == false`** (denials present) → if the denial counter < 5, continue to Step 3.4;
   if = 5, exit the loop to Phase 4 carrying the unresolved denials for the final report.

### 3.4 Delegate to: `snap-packager` (patch mode)

Provide this context to the sub-agent:
- `snap-validation-results.json` is present with `"clean": false`
- Goal: patch `snap/snapcraft.yaml` with the suggested interfaces/layouts (Step 2b), then
  rebuild the snap (Step 3), producing a new `.snap` file

Wait until a new `.snap` file is present before continuing.

Increment the denial-patch iteration count and return to **Step 3.1**.

---

## Phase 3.5: Reproducibility Loop (OCI mode only)

Runs once the denial loop exits clean (Phase 3.3 case 2) in OCI mode. Cap: **3**
iterations, tracked separately from the other two counters.

### 3.5.1 Delegate to: `snap-validator` (reproducibility check)

Provide the same context as Phase 3.2 and instruct it to run the **rootfs reproducibility
check** (its Step 3.5): re-extract from `oci.reproducibility_baseline`, `diff -rq`, and
populate the `reproducibility` block in `snap-validation-results.json`. It reports only.

### 3.5.2 Check the diff

- If `reproducibility.clean == true` (or `checked == false` because the image cannot be
  re-extracted) → **exit to Phase 4**; note the outcome for the report.
- If `reproducibility.diffs[]` is non-empty and the counter < 3 → continue to Step 3.5.3.
- If non-empty and the counter = 3 → exit to Phase 4, carrying the unresolved diffs for the
  "Unresolved Reproducibility Diffs" section.

### 3.5.3 Delegate to: `snap-packager` (patch mode) + re-enter Phase 3

Delegate to `snap-packager`'s Step 2b case (d): encode each diff as an
`override-build`/`override-prime` step and rebuild. Because a new override can in principle
reintroduce a confinement denial, **return to the full Phase 3 denial scan** (Step 3.1) with
the rebuilt `.snap`, then come back to Phase 3.5. Increment the reproducibility counter.

---

## Phase 4: Final Report

Present a consolidated summary to the user.

### Pipeline Summary

| Item | Value |
|---|---|
| Snap name | `<project.name>` from `snap-analysis.json` |
| Analyzer used | `snap-analyzer` (source) or `snap-oci-analyzer` (OCI) |
| Confinement | `<snap.confinement>` |
| Plugin | `<build.plugin>` |
| Target architecture | `<oci.target_arch>` (OCI) or `—` |
| Denial-patch iterations | `<N>` |
| Devmode | ✅ pass / ⚠️ failed after 3 build-fix attempts / `—` (non-OCI) |
| Store-review-only interfaces | list from `store_review_interfaces[]`, or `None` |
| Reproducibility | ✅ clean / ⚠️ N unresolved diffs after 3 iterations / `—` (non-OCI) |
| Final status | ✅ Clean — no denials / ⚠️ Unresolved denials after 5 iterations |

### Files Produced

| File | Purpose |
|---|---|
| `snap/snapcraft.yaml` | Snap manifest |
| `snap/hooks/*` | Lifecycle hooks (if any were generated) |
| `SNAP_PACKAGING.md` | Build, install, and connection guide |
| `<name>_<version>_<arch>.snap` | Built snap package |
| `/tmp/snap-analysis-<dir>.json` | Analysis artifact (transient, in `/tmp` — no cleanup needed) |
| `snap-validation-results.json` | Results of the last validation run |

### Interfaces Requiring Manual Connection

List every interface from `$ANALYSIS_FILE` where `"auto_connected": false`, with the
exact `snap connect <snap-name>:<plug> :<interface>` command for each.

### Store-Review-Only Interfaces (OCI mode, if any)

If `store_review_interfaces[]` is non-empty, list each interface and the app that needs it,
and warn that these (`snapd-control`, `system-files`, `docker-support`,
`kubernetes-support`) cannot be self-connected — the snap needs Snap Store manual review
before distribution. See `snap-validator`'s `references/install-and-verify.md`.

### Unresolved Denials (if loop exhausted)

If the loop hit the 5-iteration limit, list the remaining entries from the final
`snap-validation-results.json` and suggest:

1. Run `snap run --shell <snap-name>.<app>` and reproduce the failure manually
2. Check `journalctl -xe | grep -i apparmor` for additional context
3. Consult `snap-validator`'s `references/denial-to-interface.md`

### Unresolved Reproducibility Diffs (OCI mode, if loop exhausted)

If the Phase 3.5 reproducibility loop hit its 3-iteration cap, list the remaining
`reproducibility.diffs[]` entries (path + kind) and suggest:

1. Inspect the delta manually against `rootfs_original/` and encode it as an
   `override-build`/`override-prime` step in `snap/snapcraft.yaml`
2. Consult `snap-packager`'s `references/override-steps-guide.md` for the command idiom
3. Rebuild and re-run the validator's reproducibility check

---

## Error Handling

| Situation | Action |
|---|---|
| snap-analyzer / snap-oci-analyzer fails or produces invalid JSON | Stop; show the error; ask user to check the project or image reference |
| OCI dependencies unresolvable (`skopeo`/`umoci`/`jq`) | Stop; show `ensure_dependencies.py` stderr; the OCI path cannot proceed without them |
| snap-packager build fails after 3 rebuild attempts | Stop; show the last `snapcraft pack` error output |
| Devmode build-fix loop exhausted (3 attempts, OCI) | Exit to Phase 4; report the devmode failure and `devmode_notes[]` separately from denials |
| Reproducibility loop exhausted (3 iterations, OCI) | Exit to Phase 4; list unresolved diffs in the "Unresolved Reproducibility Diffs" section |
| snap-validator fails to write results | Stop; show the error; suggest running it standalone |
| Validator reports diagnostics | Stop; show each diagnostic; fix the reported pre-flight failure before rerunning validation |
| LXD container creation fails | Let snap-validator handle the retry logic |
| Classic confinement confirmed after Phase 1 | Skip Phase 3; proceed to the Final Report (Phase 4); remind user of Store approval requirement and Ubuntu Core incompatibility |
| `.snap` file missing after snap-packager runs | Stop; show the last build output |
