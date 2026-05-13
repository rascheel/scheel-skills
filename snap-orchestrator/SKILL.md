---
name: snap-orchestrator
description: >
  Coordinates snap-analyzer, snap-packager, and snap-validator as sequential
  sub-agents to take a project from source code to a validated, installable snap with correct
  interfaces. Manages the full pipeline: analyze → package → validate → patch → rebuild,
  looping the validate/patch/rebuild cycle until the snap runs clean or a maximum iteration
  limit is reached. Each sub-agent runs in its own focused context to minimize token usage.
  WHEN: full snap pipeline, snap from scratch, end-to-end snap packaging, snap build and
  validate, snap orchestrate, build and test snap, snap pipeline, automate snap packaging,
  snap workflow, package and validate snap.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.0.0"
  summary: "End-to-end snap pipeline: delegates analysis, packaging, validation, and iterative patching to focused sub-agents."
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

The sub-agents communicate exclusively through these files in the project root:

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `snap-analysis.json` | snap-analyzer | snap-packager | Full packaging specification |
| `snap/snapcraft.yaml` | snap-packager | snap-validator, snap-packager (patch) | Snap manifest |
| `snap-validation-results.json` | snap-validator | snap-packager (patch), orchestrator | Denial report |

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

If `snap-analysis.json` already exists, ask the user whether to reuse it or regenerate.
If `snap-validation-results.json` already exists, delete it before starting:

```bash
rm -f snap-validation-results.json
```

---

## Phase 1: Analysis

**Delegate to: `snap-analyzer`**

Provide this context to the sub-agent:
- Run from the current working directory (project root)
- Goal: write `snap-analysis.json`

Wait until `snap-analysis.json` is present and contains valid JSON before continuing.

If `snap-analysis.json` reports `"confinement": "classic"`, skip Phases 3–4 (validation
does not apply to classic snaps) and proceed directly to Phase 5, noting the skip.

---

## Phase 2: Initial Packaging

**Delegate to: `snap-packager`**

Provide this context to the sub-agent:
- `snap-analysis.json` is present in the project root
- No `snap-validation-results.json` is present (initial packaging mode — Step 2a)
- Goal: write `snap/snapcraft.yaml`, `snap/hooks/*`, `SNAP_PACKAGING.md`, and produce a
  built `.snap` file in the project root

Wait until a `.snap` file exists in the project root before continuing.

---

## Phase 3: Validation & Patch Loop

Maximum iterations: **5**. Track the current iteration count.

### 3.1 Delete previous results

```bash
rm -f snap-validation-results.json
```

### 3.2 Delegate to: `snap-validator`

Provide this context to the sub-agent:
- The `.snap` file in the project root is the target
- `snap/snapcraft.yaml` is available for reference
- Goal: run all apps and daemons in a clean LXD container, capture any AppArmor/SecComp
  denials, and write `snap-validation-results.json`

Wait until `snap-validation-results.json` is present before continuing.

### 3.3 Check results

Read `snap-validation-results.json`.

- If `"clean": true` → **exit the loop** and go to Phase 4.
- If `"clean": false` and iteration count < 5 → continue to Step 3.4.
- If `"clean": false` and iteration count = 5 → **exit the loop** and go to Phase 4,
  carrying the unresolved denials forward for the final report.

### 3.4 Delegate to: `snap-packager` (patch mode)

Provide this context to the sub-agent:
- `snap-validation-results.json` is present with `"clean": false`
- Goal: patch `snap/snapcraft.yaml` with the suggested interfaces (Step 2b), then rebuild
  the snap (Step 3), producing a new `.snap` file

Wait until a new `.snap` file is present before continuing.

Increment the iteration count and return to **Step 3.1**.

---

## Phase 4: Final Report

Present a consolidated summary to the user.

### Pipeline Summary

| Item | Value |
|---|---|
| Snap name | `<project.name>` from `snap-analysis.json` |
| Confinement | `<snap.confinement>` |
| Plugin | `<build.plugin>` |
| Validation iterations | `<N>` |
| Final status | ✅ Clean — no denials / ⚠️ Unresolved denials after 5 iterations |

### Files Produced

| File | Purpose |
|---|---|
| `snap/snapcraft.yaml` | Snap manifest |
| `snap/hooks/*` | Lifecycle hooks (if any were generated) |
| `SNAP_PACKAGING.md` | Build, install, and connection guide |
| `<name>_<version>_<arch>.snap` | Built snap package |
| `snap-analysis.json` | Analysis artifact (safe to commit or delete) |
| `snap-validation-results.json` | Results of the last validation run |

### Interfaces Requiring Manual Connection

List every interface from `snap-analysis.json` where `"auto_connected": false`, with the
exact `snap connect <snap-name>:<plug> :<interface>` command for each.

### Unresolved Denials (if loop exhausted)

If the loop hit the 5-iteration limit, list the remaining entries from the final
`snap-validation-results.json` and suggest:

1. Run `snap run --shell <snap-name>.<app>` and reproduce the failure manually
2. Check `journalctl -xe | grep -i apparmor` for additional context
3. Consult `snap-validator`'s `references/denial-to-interface.md`

---

## Error Handling

| Situation | Action |
|---|---|
| snap-analyzer fails or produces invalid JSON | Stop; show the error; ask user to check the project |
| snap-packager build fails after 3 rebuild attempts | Stop; show the last `snapcraft pack` error output |
| snap-validator fails to write results | Stop; show the error; suggest running it standalone |
| LXD container creation fails | Let snap-validator handle the retry logic |
| Classic confinement detected after Phase 1 | Skip Phases 3–4; note in final report that validation was skipped |
| `.snap` file missing after snap-packager runs | Stop; show the last build output |
