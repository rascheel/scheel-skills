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
The skill SHALL run every CLI app and start every daemon declared in the manifest, and record each AppArmor or seccomp denial with its app, suggested interface and raw log line. Denials MUST be deduplicated per (app, interface) pair. When no interface is suggested by the tooling, the skill SHALL map the denial using its denial-to-interface reference. `clean` MUST be true only when no denials were captured.

#### Scenario: Repeated denial
- **WHEN** the same app triggers the same `network-bind` denial three times
- **THEN** `denials[]` contains one entry for that app and interface

#### Scenario: No denials
- **WHEN** all apps and daemons run without denials
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
The skill SHALL present a per-app table of denials and suggested plugs, and always report the devmode result and any store-review interfaces. In OCI mode it SHALL also report the test environment and reproducibility status.

#### Scenario: Clean run
- **WHEN** validation finishes with no denials
- **THEN** the summary shows "None" for each app and the devmode result
