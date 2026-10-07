# snapcraft-author Specification

## Purpose
Turns `snap-analysis.json` into a buildable snap: writes `snap/snapcraft.yaml`, lifecycle hooks and `SNAP_PACKAGING.md`, then builds the `.snap`. In patch mode it applies fixes reported by `snap-validator` and rebuilds. It is the only skill in the pipeline that writes the manifest.

## Requirements

### Requirement: Analysis is required
The skill SHALL read the analysis from `/tmp/snap-analysis-<dirname>.json`, falling back to `./snap-analysis.json`. If neither exists it MUST stop and tell the user to run an analyzer first. It MUST take plugin, confinement, interface, hook and layout decisions from the analysis without re-inspecting the source or second-guessing them.

#### Scenario: No analysis present
- **WHEN** neither analysis path exists
- **THEN** the skill stops and tells the user to run `snap-analyzer` or `snap-oci-analyzer`

### Requirement: Initial packaging outputs
With no failing validation results, the skill SHALL write a complete `snap/snapcraft.yaml` with no placeholder comments, one `snap/hooks/<name>` script per entry in `hooks[]`, and a `SNAP_PACKAGING.md` covering prerequisites, build command, devmode and strict install, `snap connect` for every interface with `auto_connected: false`, a `snap set` example with the default for every snap option, troubleshooting, and the analysis `notes[]`. It MUST write them directly, not show drafts for approval.

#### Scenario: Manual-connect interface
- **WHEN** the analysis lists `camera` with `auto_connected: false`
- **THEN** `SNAP_PACKAGING.md` includes the exact `snap connect <snap>:camera` command

#### Scenario: No hooks in analysis
- **WHEN** `hooks[]` is empty
- **THEN** no files are created under `snap/hooks/`

#### Scenario: Source build with snap options
- **WHEN** a source analysis records `daemon.port`, `daemon.host` and `daemon.msg` in `config_options[]`
- **THEN** `SNAP_PACKAGING.md` shows a `snap set <snap>` example for each of the three keys

### Requirement: Manifest rules for source builds
For source analyses the manifest SHALL use `base: core24` and MUST NOT set `build-base`. It MUST NOT set `confinement: devmode`. When `build.override_build_extra` is set, the part's `override-build` MUST run `craftctl default` before the extra commands. The skill SHALL prefer `stage-packages` and `build-packages` over `stage-snaps` and `build-snaps` so CVE reporting keeps working.

#### Scenario: Extra post-build steps
- **WHEN** `build.override_build_extra` is non-null
- **THEN** the part's `override-build` starts with `craftctl default` followed by those commands

### Requirement: Architecture pinning
When the effective target architecture is set, the manifest SHALL contain a single-entry `platforms:` stanza whose key and `build-for` equal that architecture, with `build-on: [amd64, arm64]`. When it is null, `platforms:` MUST be omitted.

#### Scenario: Host build
- **WHEN** the analysis has no `oci` block and `target_arch` is null
- **THEN** the manifest has no `platforms:` stanza

#### Scenario: Cross-architecture source build
- **WHEN** top-level `target_arch` is `riscv64`
- **THEN** `platforms:` has a single `riscv64` entry with `build-for: [riscv64]`

### Requirement: OCI rendering
When the analysis has an `oci` block, the skill SHALL refine the `docker-to-snap` scaffold manifest in place rather than starting from the blank template. It SHALL keep the scaffold's `base:` (which the analysis's `snap.base` mirrors; the scaffold wins if they differ) and `platforms:` stanza, generating `platforms:` from `oci.target_arch` only if the scaffold lacks it. It SHALL render `system-usernames`, override steps, content-interface slots and plugs, and configure/install hook bodies from the `oci.*` facts. It MUST append to the generated install hook and merge the `hooks:` stanza instead of replacing them.

#### Scenario: Scaffold already pins the architecture
- **WHEN** the scaffold's `platforms:` entry matches `oci.target_arch`
- **THEN** the stanza is kept unchanged

#### Scenario: Non-root image
- **WHEN** `oci.system_usernames.needed` is true
- **THEN** the manifest declares `system-usernames` and the app drops privileges using the recorded method

#### Scenario: Content path also has a layout
- **WHEN** a content plug's target and a layout would bind the same path
- **THEN** only the content plug is rendered

### Requirement: Source tree is never modified
The skill MUST NOT write to a container `rootfs/`. Every change the image needs SHALL be encoded as an `override-build` or `override-prime` step. glibc mismatches MUST be handled by RPATH embedding and never by adding `LD_LIBRARY_PATH`.

#### Scenario: glibc mismatch in OCI mode
- **WHEN** `oci.glibc_compat.mitigation` is `rpath_embed`
- **THEN** an `override-build` step calls the scaffold's generated `embed_rpath.sh`
- **AND** no `LD_LIBRARY_PATH` is added to any app environment

### Requirement: Patch mode
When `snap-validation-results.json` is present with `clean: false`, the skill SHALL patch the existing manifest and rebuild instead of regenerating it. Non-empty `diagnostics[]` MUST stop the skill without changing the manifest or rebuilding. Otherwise each remediation SHALL be applied by kind:
- A denial adds the suggested interface to that app's plugs, without creating duplicates.
- A denial on a hardcoded path adds a layout.
- `devmode_pass: false` is fixed at its root cause (command path, install step, interpreter or RPATH) without changing plugs or layouts.
- In OCI mode, each reproducibility diff becomes an override step.

#### Scenario: Denial suggests an existing plug
- **WHEN** a denial suggests `network` and the app already plugs `network`
- **THEN** the plug list is unchanged

#### Scenario: Devmode crash
- **WHEN** results have `devmode_pass: false` with notes pointing to a wrong command path
- **THEN** the command path is corrected and no plugs or layouts are added

#### Scenario: Validation diagnostics
- **WHEN** results contain a `missing-snap` diagnostic
- **THEN** the skill reports it and stops without editing the manifest

### Requirement: Safe incremental edits
Incremental changes to app plugs, layouts and part override steps SHALL go through `patch_snapcraft.py`. The script is idempotent, supports a dry run, and backs up the manifest to `snapcraft.yaml.bak` before saving. Layouts MUST be rejected when they fall in off-limits areas such as `/run`, `/proc`, `/sys`, `/dev`, `/bin` or `/usr/lib`.

#### Scenario: Reapplying the same patch
- **WHEN** the same plug, layout and override command are applied twice
- **THEN** the manifest after the second run equals the manifest after the first

### Requirement: Isolated, traceable builds
The skill SHALL build with `snapcraft pack` and `SNAPCRAFT_BUILD_INFO=1`, retrying after fixes up to 3 attempts. It MUST NOT use `--destructive-mode`.

#### Scenario: Build keeps failing
- **WHEN** the third build attempt fails
- **THEN** the skill stops and reports the last `snapcraft pack` error

### Requirement: Chat report
After a successful build, the skill SHALL report the files created, the plugin and confinement, the interfaces that need `snap connect`, and analysis notes the user should act on.

#### Scenario: Build succeeds
- **WHEN** a `.snap` is produced
- **THEN** the report lists `snap/snapcraft.yaml`, any hooks, `SNAP_PACKAGING.md` and the `.snap` file

### Requirement: Configure hook for source builds
When a source analysis records top-level `config_options[]`, the generated `configure` hook SHALL, for each option: validate the value by its type (including `true`/`false` for `boolean`) only when it is non-empty, so an unset key never fails `snap set`; and, when `restart_required` is true, restart each daemon app only if that daemon is currently active. For options with `source: "snapctl"` the hook MUST NOT write a config file, because the app reads the value itself.

#### Scenario: Option changed on a running daemon
- **WHEN** an option has `restart_required: true` and the user runs `snap set` with a valid value while the daemon is running
- **THEN** the hook accepts the value and restarts the daemon

#### Scenario: Invalid value
- **WHEN** the user sets a `boolean` option to `maybe`, or an `enum` option to a value outside `allowed_values`
- **THEN** the hook exits non-zero with a message naming the key, and `snap set` fails

#### Scenario: Hook runs at install time
- **WHEN** snapd runs the `configure` hook during installation, before any service has started
- **THEN** the hook succeeds without restarting anything

#### Scenario: App reads snapctl itself
- **WHEN** every recorded option has `source: "snapctl"`
- **THEN** the hook writes no config file

### Requirement: Install hook seeds option defaults
When a source analysis records top-level `config_options[]` and lists `install` in `hooks[]`, the install hook SHALL seed each option's non-null default with `snapctl set`, only if that key is unset.

#### Scenario: Default seeded on first install
- **WHEN** an option `log.level` has default `info` and is unset at install time
- **THEN** the install hook sets `log.level` to `info`

#### Scenario: Existing value kept
- **WHEN** the user has already set `log.level` before the install hook runs
- **THEN** the install hook leaves the value unchanged

### Requirement: Command wrappers pass arguments through
When the skill renders a wrapper script for a command app (`daemon: null`), the wrapper SHALL end by exec'ing the binary with `"$@"`, and MUST NOT hardcode a path or flag that the user would choose on each run. The skill SHALL render every app the analysis lists, with the app type the analysis records.

#### Scenario: Wrapped command app
- **WHEN** the analysis lists a command app whose command is a wrapper script
- **THEN** the generated wrapper's last command is `exec "$SNAP/<path-to-binary>" "$@"` and running `<snap> <dir>` passes `<dir>` to the binary

#### Scenario: Command and service apps
- **WHEN** the analysis lists a command app and a service app named `daemon`
- **THEN** `snapcraft.yaml` has both apps, and only `daemon` has a `daemon:` key
