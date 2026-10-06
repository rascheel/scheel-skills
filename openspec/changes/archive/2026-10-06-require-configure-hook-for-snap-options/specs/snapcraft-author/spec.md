## ADDED Requirements

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

## MODIFIED Requirements

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
