# snap-validator Specification

## Purpose
Installs a built snap in a disposable LXD environment, runs its apps and daemons, and reports AppArmor/seccomp denials, startup crashes, interfaces that need Snap Store review, and (for OCI snaps) reproducibility diffs in `snap-validation-results.json`. It only reports; it never patches or rebuilds.

## Requirements

### Requirement: Report only
The skill MUST NOT modify `snap/snapcraft.yaml`, rebuild the snap, change override steps, or swap directories in any phase. It SHALL communicate its findings only through `snap-validation-results.json` and a chat summary.

#### Scenario: Denials found
- **WHEN** the strict scan captures denials
- **THEN** they are written to `snap-validation-results.json` and the manifest is unchanged

### Requirement: Classic snaps are rejected
If the manifest declares `confinement: classic`, the skill MUST stop immediately with a message that classic snaps are out of scope, before creating any container.

#### Scenario: Classic snap
- **WHEN** `snap/snapcraft.yaml` has `confinement: classic`
- **THEN** the skill stops and no LXD container is created

### Requirement: Isolated test environment with guaranteed cleanup
The skill SHALL install the snap with `--dangerous` inside a fresh LXD container, never on the host. It MUST delete the container at the end of the run, including after a failure.

#### Scenario: Install fails mid-run
- **WHEN** `snap install` fails inside the container
- **THEN** the skill reports the exact error and still deletes the container

### Requirement: Architecture-aware environment
When the effective target architecture (`oci.target_arch`, or top-level `target_arch` for source builds) differs from the host, the skill SHALL pick a test environment that can run that architecture (LXD remote, full emulation, or a user-mode QEMU smoke test) and record it in `test_environment_used`. When a target is set and matches the host, it SHALL use native LXD and record `"native-lxd"`. When no target is set, `target_arch` and `test_environment_used` MUST be null.

#### Scenario: arm64 snap on an amd64 host
- **WHEN** the effective target architecture is `arm64` and the host is `amd64`
- **THEN** a non-native environment is used and named in `test_environment_used`

#### Scenario: Host build
- **WHEN** there is no effective target architecture
- **THEN** `target_arch` and `test_environment_used` are null

### Requirement: Devmode crash check first
For every snap, the skill SHALL install and start it in devmode before the strict scan. If the snap crashes on start, it MUST set `devmode_pass: false`, record the evidence in `devmode_notes[]`, write results with `denials: []`, and stop before the strict scan without suggesting plugs or layouts. Otherwise it SHALL set `devmode_pass: true`.

#### Scenario: Binary exits immediately with no output
- **WHEN** the entrypoint exits silently in devmode
- **THEN** `devmode_pass` is false, `devmode_notes[]` quotes the evidence, and no strict scan runs

### Requirement: Strict-mode denial capture
The skill SHALL run every CLI app and start every daemon declared in the manifest, and record each AppArmor or seccomp denial with its app, suggested interface and raw log line. Denials MUST be deduplicated per (app, interface) pair. When no interface is suggested by the tooling, the skill SHALL map the denial using its denial-to-interface reference. `clean` MUST be true only when no denials were captured and `diagnostics[]` is empty.

#### Scenario: Repeated denial
- **WHEN** the same app triggers the same `network-bind` denial three times
- **THEN** `denials[]` contains one entry for that app and interface

#### Scenario: No denials
- **WHEN** all apps and daemons run without denials and no diagnostic is recorded
- **THEN** results have `clean: true` and `denials: []`

### Requirement: Store-review interface flagging
On every run, the skill SHALL check suggested and declared interfaces against those that need manual Snap Store review (`snapd-control`, `system-files`, `docker-support`, `kubernetes-support`) and list each match with its app in `store_review_interfaces[]`. A match MUST NOT fail the run.

#### Scenario: Snap declares system-files
- **WHEN** an app plugs `system-files`
- **THEN** `store_review_interfaces[]` lists it with that app, and `clean` is unaffected by the match

### Requirement: OCI reproducibility check
In OCI mode, when asked to check reproducibility, the skill SHALL re-extract the original image by replaying the recorded extraction command, compare it with the working `rootfs/`, and report each difference as `added`, `removed` or `modified` in `reproducibility.diffs[]`. If the image cannot be re-extracted it MUST set `reproducibility.checked: false` without failing the run. Outside OCI mode, `oci_mode` MUST be false and `reproducibility` MUST be null.

#### Scenario: Recipe reproduces cleanly
- **WHEN** the re-extracted rootfs matches the working rootfs
- **THEN** `reproducibility` has `checked: true`, `clean: true` and `diffs: []`

#### Scenario: Tarball no longer available
- **WHEN** the baseline tarball cannot be found or downloaded
- **THEN** `reproducibility.checked` is false and the run still completes

### Requirement: Summary
The skill SHALL present a per-app table of denials and suggested plugs, and always report the devmode result, any store-review interfaces, and the snap option check result when one ran. In OCI mode it SHALL also report the test environment and reproducibility status.

#### Scenario: Clean run
- **WHEN** validation finishes with no denials
- **THEN** the summary shows "None" for each app and the devmode result

#### Scenario: Snap option check ran
- **WHEN** `config_check` is non-null
- **THEN** the summary states the key, the value set, whether it was a changed or re-applied value, and whether `snap set` succeeded and daemons stayed active, or why the check did not run

### Requirement: Snap option check
When the analysis records snap options (top-level or under `oci`), the skill SHALL, after the strict-mode scan, run `snap set` on one option. For any option type it SHALL re-apply the option's current value (or `snap unset` it when unset). It MUST check that the command exits `0` and every daemon stays active, record the outcome in `config_check`, and add any denials seen during the check to `denials[]`.

#### Scenario: String option re-applied
- **WHEN** the only recorded option is a `string` option and the snap has a working `configure` hook
- **THEN** `config_check` has `checked: true`, `value_changed: false`, `set_ok: true` and `daemons_active: true`, and no diagnostic is added

### Requirement: Enum options are changed and restored
When a recorded `enum` option has another value in `allowed_values`, the skill SHALL use that option for the check: set the other value, check that daemons stay active, then restore the original value, and record `value_changed: true`. No other option type SHALL be set to a different value.

#### Scenario: Enum option changed
- **WHEN** the analysis records an `enum` option with allowed values `info` and `debug`, currently `info`
- **THEN** the skill sets it to `debug`, checks the daemons, sets it back to `info`, and records `value_changed: true`

#### Scenario: Boolean option not toggled
- **WHEN** the only recorded option is a `boolean` option currently `false`
- **THEN** the skill re-applies `false` and records `value_changed: false`

### Requirement: Rejected snap set is a diagnostic
If `snap set` or `snap unset` fails during the snap option check, the skill MUST add a `config-set-failed` entry to `diagnostics[]` carrying snapd's error, and set `config_check.set_ok: false`.

#### Scenario: Options recorded but the snap has no configure hook
- **WHEN** the analysis records snap options and snapd rejects `snap set` because the snap has no `configure` hook
- **THEN** results have `clean: false`, `config_check.set_ok: false`, and a `config-set-failed` diagnostic quoting snapd's error

### Requirement: Snap option check not run
When the manifest declares a `configure` hook but the analysis records no snap option, the skill SHALL set `config_check.checked: false` with the reason in `notes`, without failing the run. With no snap options and no `configure` hook, `config_check` MUST be null.

#### Scenario: Hook without recorded options
- **WHEN** the manifest has a `configure` hook and the analysis records no snap options
- **THEN** `config_check.checked` is false with a reason and `clean` is unaffected

#### Scenario: No snap options
- **WHEN** the analysis records no snap options and the manifest has no `configure` hook
- **THEN** no `snap set` is run and `config_check` is null
