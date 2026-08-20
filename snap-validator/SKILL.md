---
name: snap-validator
description: >
  Validates snap packages by provisioning a clean LXD container, installing with
  --dangerous, running all declared CLI apps and daemons, and capturing AppArmor/SecComp
  denials via snappy-debug. Records denials in snap-validation-results.json for
  snap-packager to act on — never patches snapcraft.yaml directly. Hard-stops for classic
  confinement. Runs a devmode-first crash check and flags store-review-only interfaces for
  every snap. For OCI-derived snaps it also selects an architecture-appropriate test
  environment and reports rootfs reproducibility diffs — all report-only. WHEN: validate snap interfaces,
  test snap in LXD, snap AppArmor denials, snap security testing, find snap plugs, snap
  confinement issues, snappy-debug scan, snap runtime testing, snap permissions audit,
  snapcraft.yaml interfaces, snap seccomp denial, snap access denied, devmode crash check,
  ELF interpreter crash, store-review-only interfaces, snap rootfs reproducibility,
  architecture-aware snap test environment.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.3.0"
  summary: "Runs a snap in LXD: reports denials, devmode, store-review interfaces, and arch-aware test env; OCI reproducibility — never patches yaml."
  tags:
    - snap
    - snapcraft
    - lxd
    - security
    - validation
---

# Snap Validator

Provisions a clean LXD container, installs the locally built snap, exercises every declared
app and daemon, captures AppArmor/SecComp denials with `snappy-debug`, and **reports** the
plugs that are actually required. Classic-confinement snaps are excluded.

> **This skill never patches `snapcraft.yaml` and never rebuilds.** It validates and
> *reports*; the caller (typically `snap-orchestrator`, acting through `snap-packager`)
> patches and rebuilds. This is true for every phase below, including the OCI reproducibility
> phase, which only computes and reports the diff.

**Every run** (OCI or source-built) gets a **devmode-first crash check** before the strict
scan (§2.5) and a **store-review-only interface cross-check** during the strict scan
(§3.4) — neither has any real OCI dependency; a build/exec correctness bug or a
store-review-only interface need can arise for a source-built snap just as much as an
OCI-derived one.

**OCI mode.** For OCI-derived snaps the base flow is additionally wrapped with extra
behaviors — **architecture-aware environment selection** during the strict scan (§2.0),
and a **rootfs reproducibility diff** once confinement is clean (§3.5). These remain gated
on OCI mode and all remain report-only. In the base (source-code) case neither runs and the
output is byte-for-byte the original single-pass strict flow with the new fields null.

---

## Step 1: Discovery & Pre-Flight

### 1.1 Parse snapcraft.yaml

Read `snap/snapcraft.yaml` and extract:

- `snap_name` — value of the top-level `name:` key
- `confinement` — value of the top-level `confinement:` key (default: `strict`)
- `apps` — for each entry under `apps:`, record `name`, `command`, and `daemon` (null if absent)

### 1.1a Detect OCI mode

Read `$ANALYSIS_FILE` (`/tmp/snap-analysis-$(basename "$PWD").json`) when the caller
provides it — `snap-orchestrator` passes this path. **OCI mode is true iff the analysis
file's top-level `oci` key is present.** If the analysis file was not passed, fall back to
detecting a `rootfs/` directory in the project root as a secondary signal. When OCI mode is
true, also read `oci.target_arch` and `oci.reproducibility_baseline` — the arch-selection
(§2.0) and reproducibility (§3.5) phases need them. §2.5 (devmode) and §3.4 (store-review)
run regardless of OCI mode. In non-OCI mode, skip §2.0 and §3.5 entirely, and leave
`target_arch`, `test_environment_used`, and `reproducibility` at their null defaults (§4.2).

### 1.2 Classic confinement gate

**If `confinement: classic`:** Output the message below and **STOP immediately**.

> ⛔ This snap uses classic confinement. Classic snaps are excluded from this skill —
> they run without AppArmor mediation and interface-based patching does not apply.

### 1.3 Categorise apps

From the parsed output, split apps into two lists:

- **CLI apps** — entries where `daemon` is `null`
- **Daemons** — entries where `daemon` is `simple`, `forking`, or `notify`

---

## Step 2: Environment Setup

Provision a clean container and install prerequisites. Replace `<snap-file>` with the
actual `.snap` filename found in the working directory. If no `.snap` exists, ask the
user to build one first (`snapcraft`).

### 2.0 Architecture-aware environment selection (OCI mode)

When OCI mode is on and `oci.target_arch` **does not match the host architecture**, a plain
native `lxc launch ubuntu:24.04` cannot run the snap. Select the test environment using the
decision tree in `references/build-environments.md` (native LXD when arch matches; an LXD
remote on matching hardware; full-system emulation with snapd; or a QEMU/binfmt smoke test
when only a shallow "does it start" check is possible). Record the choice as
`test_environment_used` (e.g. `"native-lxd"`, `"lxd-remote"`, `"qemu-user-static"`,
`"image-garden"`). In non-OCI mode, or when arch matches the host, use native LXD and set
`test_environment_used` to `"native-lxd"` (OCI) or leave it `null` (non-OCI).

```bash
# Native LXD (arch matches host) — the default
lxc launch ubuntu:24.04 snap-test-env \
  -c security.nesting=true \
  -c security.privileged=false

# Wait for initialisation
lxc exec snap-test-env -- cloud-init status --wait

# Install required tools
lxc exec snap-test-env -- apt-get install -y squashfuse snappy-debug

# Transfer the snap
lxc file push <snap-file>.snap snap-test-env/tmp/<snap-file>.snap

# Install the snap (unsigned/local)
lxc exec snap-test-env -- snap install --dangerous /tmp/<snap-file>.snap
```

---

## Step 2.5: Devmode-first crash check

> **Run this before the strict scan (Step 3), for every snap.** Ported from
> `snap-iteration-workflow` Phase 3 — see `references/install-and-verify.md`.

A snap can fail to *run at all* (wrong ELF interpreter, bad library layout, a build-time
bug unrelated to confinement) before confinement is ever exercised — this is most common
for OCI-derived snaps (foreign glibc, vendored binaries) but source-built snaps can hit it
too. Burning an LXD strict cycle on a snap that does not start is wasteful, so validate
startup in `--devmode` first, for every run:

```bash
# Inside the selected test environment
snap remove --purge <snap-name> 2>/dev/null || true
snap install --dangerous --devmode /tmp/<snap-file>.snap
# For daemons:
snap start <snap-name>.<app> 2>/dev/null || true
snap logs -f <snap-name>.<app> &   # watch briefly
# For CLI apps:
<snap-name>.<app> --help 2>&1 | head -20 || true
```

Confirm the entrypoint/daemon starts without crashing and the logs show no ELF-interpreter
or library errors.

> **ELF interpreter crash pattern:** if the process exits immediately with **no output**,
> the interpreter layout or `LD_LIBRARY_PATH` is wrong — a **build-correctness** bug, not a
> confinement issue. Record it in `devmode_notes[]` (quote the log/exit evidence).

- **Pass:** set `devmode_pass: true`, `devmode_notes: []`, and continue to Step 3.
- **Fail:** set `devmode_pass: false`, populate `devmode_notes[]`, write results, and
  **STOP before the strict scan.** The orchestrator routes this to `snap-packager`'s
  build-fix branch (not the denial-patch loop) — do not suggest plugs or layouts for a
  crash-on-start failure.

---

## Step 3: Execution & Monitoring Loop

Process each app in turn. Maintain a running denial log throughout.

### 3.1 CLI apps

```bash
# Start snappy-debug in the background
lxc exec snap-test-env -- snappy-debug &

# Run the app
lxc exec snap-test-env -- <snap-name>.<app-name>

# Collect AppArmor/SecComp lines
lxc exec snap-test-env -- journalctl -xe --no-pager | grep -iE "apparmor|seccomp"
```

### 3.2 Daemons

```bash
# Start the service
lxc exec snap-test-env -- snap start <snap-name>.<app-name>

# Stream logs while snappy-debug scans (30 s)
lxc exec snap-test-env -- journalctl -fu snap.<snap-name>.<app-name> --no-pager &
lxc exec snap-test-env -- snappy-debug --scan

# Collect denial lines
lxc exec snap-test-env -- journalctl -xe --no-pager | grep -iE "apparmor|seccomp"
```

### 3.3 Record each denial

For every denial captured, record:

1. **App name** — which app entry triggered it
2. **snappy-debug suggestion** — e.g., `suggested plug: network-bind`
3. **Raw AppArmor line** — for traceability in the summary

Consult `references/denial-to-interface.md` when snappy-debug gives no explicit
suggestion — it maps common denial patterns to the correct snap interface.

### 3.4 Store-review-only interface detection

Runs for every snap, OCI or source-built — this is a pure lookup-table check against
whatever interfaces are already being suggested/declared, with no OCI dependency.

Cross-reference every interface that was **denial-suggested** (Step 3.3) or already
**declared** in `snapcraft.yaml` against the known store-review-only list — interfaces that
cannot be self-connected and require Snap Store manual review:

`snapd-control`, `system-files`, `docker-support`, `kubernetes-support`.

For each match, add an entry to `store_review_interfaces[]` (the interface name and which
app needs it). See `references/install-and-verify.md` → "Identify store-review-only
interfaces early". These are reported, not blocking — they inform the user of extra Store
review time.

---

## Step 4: Write Results

### 4.1 Map each denial to its app

Identify which `apps:` entry in `snapcraft.yaml` caused each denial.

### 4.2 Write snap-validation-results.json

Write `snap-validation-results.json` to the project root using this schema (bumped to
`"1.1"`). All base fields are unchanged; the OCI fields are optional and take their
null/empty defaults in the base case, so schema-1.0 consumers keep working:

```json
{
  "schema_version": "1.1",
  "snap_name": "<name>",
  "confinement": "<confinement>",
  "clean": false,
  "denials": [
    {
      "app": "<app-name>",
      "interface_suggestion": "<plug-name>",
      "raw_denial": "<full AppArmor/SecComp log line>"
    }
  ],

  "oci_mode": false,
  "devmode_pass": null,
  "devmode_notes": [],
  "target_arch": null,
  "test_environment_used": null,
  "store_review_interfaces": [],
  "reproducibility": null
}
```

- Set `"clean": true` and `"denials": []` when no denials were found.
- Set `"interface_suggestion"` to the plug name from snappy-debug, or look up the denial
  in `references/denial-to-interface.md` if snappy-debug gives no suggestion.
- Write one denial object per unique `(app, interface_suggestion)` pair — deduplicate.
- Use `diagnostics[]` for validation failures that are not confinement denials, such as
  a missing `.snap` artifact. Each entry has a machine-readable `code` and a human-readable
  `message`; keep `denials[]` exclusively for valid denial objects.
- **`devmode_pass`/`devmode_notes[]`** are populated from Step 2.5 for every run, OCI or
  source-built — `devmode_pass` is `true`/`false`.
- **`store_review_interfaces[]`** is populated from Step 3.4 for every run, OCI or
  source-built — it stays `[]` only when the snap genuinely needs none of the four
  store-review-only interfaces.
- **OCI-only fields:** set `oci_mode: true` in OCI mode. `target_arch` from
  `oci.target_arch`; `test_environment_used` from Step 2.0. `reproducibility` is populated
  only by Step 3.5 (below), otherwise `null`.
- When `devmode_pass: false`, write the results and stop after Step 2.5 — `clean` reflects
  that the strict scan did not run (leave `denials: []`); the build fix is the caller's job.

**Do not patch `snapcraft.yaml` or rebuild the snap.** The caller (or the
`snap-orchestrator` skill) is responsible for acting on the results.

---

## Step 3.5: Rootfs reproducibility check (OCI mode only)

> **OCI mode only, and only when invoked for the reproducibility check** — the orchestrator
> calls this once the denial loop is clean (Phase 3.5). Skip in the base case. Ported from
> `snap-iteration-workflow` Phase 5 / `snap-oci-container` Phase 6. **Report only — this
> skill never patches or rebuilds.**

Prove the recipe reproduces the snap from a clean extraction:

1. Re-extract the original image into `rootfs_original/` using
   `oci.reproducibility_baseline.tarball_path` and the exact
   `extraction_command_recorded` (replay it verbatim, adding an isolated
   `--output-folder`, then move its `rootfs/` to `rootfs_original/`).
2. Diff against the working tree:
   ```bash
   diff -rq rootfs_original/ rootfs/
   ```
3. Populate the `reproducibility` block and **report** — do not encode overrides or swap
   directories here:

```json
"reproducibility": {
  "checked": true,
  "diffs": [ { "path": "...", "kind": "added | removed | modified", "detail": "..." } ],
  "clean": true
}
```

- `kind`: `added` = present only in working `rootfs/`; `removed` = present only in
  `rootfs_original/`; `modified` = content/symlink/permission/owner differs.
- Set `"clean": true` and `"diffs": []` when the diff is empty (the recipe is fully
  reproducible).
- If the original image cannot be reproduced (no tarball, download fails), set
  `"checked": false`, leave `diffs: []`, and note the reason in `devmode_notes`/summary.

The orchestrator routes any non-empty `diffs[]` to `snap-packager` (which encodes them as
override steps) and loops back; this skill's role ends at reporting the diff.

---

## Step 5: Completion & Cleanup

### 5.1 Confirm clean run

A clean run is when all apps and daemons finish without producing any AppArmor/SecComp
denials. `snap-validation-results.json` will have `"clean": true`.

### 5.2 Present summary table

| App / Daemon | Denials Found | Plugs Suggested |
|---|---|---|
| `<app-name>` | `<denial or "None">` | `<plug(s) or "None">` |

Always report devmode pass/fail (with any ELF-crash note) and store-review-only interfaces
required. In OCI mode, also report: the test environment used and reproducibility status
(clean / N diffs).

### 5.3 Cleanup — always execute

```bash
lxc delete --force snap-test-env
```

> ⚠️ Run this even if earlier steps failed.

---

## Error Handling

| Situation | Action |
|---|---|
| No `.snap` file found | Write `snap-validation-results.json` with `"clean": false` and a note in `denials`; stop |
| LXD not installed or unavailable | Stop: "lxc is not available on this system" |
| `snap install` fails | Report exact error; do not continue |
| Denial with no snappy-debug suggestion | Read `references/denial-to-interface.md` |
| Container creation fails | Try `ubuntu:noble` as an alternative image |
| `cloud-init` times out | Wait 60 s and retry; if still failing, recreate container |
| Devmode start fails | Set `devmode_pass: false` + `devmode_notes[]`; stop before strict scan; caller runs the build-fix branch |
| Target arch ≠ host (OCI) | Select an environment per `references/build-environments.md`; record `test_environment_used` |
| Original image not reproducible (OCI) | Set `reproducibility.checked: false`; note the reason; do not fail the run |

---

## Resources

| File | Purpose |
|---|---|
| `references/denial-to-interface.md` | Maps AppArmor denial patterns to snap interface names |
| `references/install-and-verify.md` | Devmode install, ELF-crash pattern, `snap try`, store-review-only interface identification (OCI mode) |
| `references/build-environments.md` | Architecture-aware test-environment decision tree (OCI cross-arch) |
