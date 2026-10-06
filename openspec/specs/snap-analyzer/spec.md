# snap-analyzer Specification

## Purpose
Scans an application's source code and produces `snap-analysis.json`, the packaging specification that `snapcraft-author` turns into a snap. It records facts and decisions only and never writes snap artifacts.

## Requirements

### Requirement: Analysis output only
The skill SHALL write exactly one output, the analysis file at `/tmp/snap-analysis-<dirname>.json`, and MUST NOT generate `snapcraft.yaml`, hooks, or any other snap artifact.

#### Scenario: Analysis completes
- **WHEN** the analyzer finishes on a source project
- **THEN** the analysis file exists at the `/tmp` path and validates against `schema/snap-analysis.schema.json`
- **AND** no `snap/` directory or `snapcraft.yaml` has been created or modified

### Requirement: Evidence from the repository
The skill SHALL derive language, build system, entry points, app type, resource usage, hardcoded paths and version from files in the repository. It MUST NOT ask the user for information that can be read from the repository.

#### Scenario: Version is in a manifest file
- **WHEN** the project's version is declared in `go.mod`, `package.json`, `setup.py`, `CMakeLists.txt`, a `VERSION` file or a git tag
- **THEN** `project.version` is taken from it without asking the user

### Requirement: Strict confinement by default
The skill SHALL record `snap.confinement: strict` unless the app cannot work within snap interfaces. Before recording `classic`, it MUST ask the user and warn that classic snaps need manual Snap Store approval (typically 3–5 business days, not guaranteed) and do not run on Ubuntu Core.

#### Scenario: App fits strict confinement
- **WHEN** the app's needs can be met by snap interfaces
- **THEN** the analysis records `confinement: strict` without asking the user

#### Scenario: User confirms classic
- **WHEN** classic appears necessary and the user explicitly confirms it after the warning
- **THEN** the analysis records `confinement: classic`, a `classic_reason`, and both caveats in `notes[]`

#### Scenario: User declines classic
- **WHEN** classic appears necessary but the user chooses strict
- **THEN** the analysis records `confinement: strict` and maps interfaces to cover the app's needs

### Requirement: Plugin selection
The skill SHALL record a snapcraft plugin in `build.plugin` that matches the project's build system (`go`, `python`, `npm`, `cmake`, `meson`, `rust`, `nil` for non-standard builds, or `dump` for prebuilt artifacts). Post-build steps needed on top of a language plugin MUST be recorded in `build.override_build_extra` rather than by switching plugins.

#### Scenario: Go module project
- **WHEN** the project root contains `go.mod`
- **THEN** `build.plugin` is `go`

### Requirement: Interface mapping
For every system resource the app uses, the skill SHALL record an interface in `interfaces[]` with the apps that need it, whether it auto-connects, and a one-sentence reason. `apps[].plugs` MUST list interface names only.

#### Scenario: Network server
- **WHEN** the app listens on a network socket
- **THEN** `interfaces[]` contains `network-bind` with `auto_connected: true` and a reason, and the listening app's `plugs` includes `network-bind`

### Requirement: Hooks and layouts only when needed
The skill SHALL list a hook in `hooks[]` only for a real lifecycle need (first-run setup, snap options, interface connect/disconnect, or refresh migration), and SHALL add `layouts` entries only for paths the app hardcodes outside snap-writable locations. Recording any snap option is a need that MUST add `configure`, because snapd rejects `snap set` on a snap without that hook. With no need, `hooks` MUST be `[]`.

#### Scenario: Stateless CLI tool
- **WHEN** the app is a CLI with no setup, config or migration needs
- **THEN** `hooks` is `[]`

#### Scenario: Options recorded
- **WHEN** the analysis records snap options
- **THEN** `hooks[]` contains `configure`, and the analysis passes `schema/validate_contracts.py`

### Requirement: Target architecture
The skill SHALL set top-level `target_arch` to `null` unless a non-host architecture is requested by the caller or the user. When one is requested, it MUST record one of the allowed architecture names. In every case `schema_version` SHALL be the current analysis version, `"1.3"`.

#### Scenario: Cross-architecture request
- **WHEN** snap-builder passes target architecture `arm64`
- **THEN** the analysis has `target_arch: "arm64"` and `schema_version: "1.3"`

#### Scenario: No architecture requested
- **WHEN** no target architecture is given
- **THEN** the analysis has `target_arch: null` and `schema_version: "1.3"`

### Requirement: Chat report
After writing the analysis, the skill SHALL report its full `/tmp` path along with the chosen plugin, confinement, interfaces (split into auto-connected and manual), hooks, snap options, layouts, and any assumptions recorded in `notes[]`.

#### Scenario: Manual-connect interface present
- **WHEN** the analysis includes an interface with `auto_connected: false`
- **THEN** the report names it as needing `snap connect`

#### Scenario: Snap options recorded
- **WHEN** the analysis records snap options
- **THEN** the report lists each key with its default

### Requirement: Snap options are recorded
When the app's code, wrapper or planned hooks read a snap option with `snapctl get`, or the analysis plans to seed one with `snapctl set`, the skill SHALL record each option once in top-level `config_options[]` with its key, `source: "snapctl"`, a type, its default (or `null`), and `restart_required`, which is true when a running daemon reads the option only at startup. It MUST then list `configure` in `hooks[]`, and SHALL list `install` when any recorded option has a non-null default to seed.

#### Scenario: Daemon reads options at startup
- **WHEN** a daemon script reads `daemon.port`, `daemon.host` and `daemon.msg` with `snapctl get` once at startup and needs defaults
- **THEN** `config_options[]` lists all three keys with `source: "snapctl"`, their defaults and `restart_required: true`
- **AND** `hooks[]` contains both `install` and `configure`

#### Scenario: On/off flag
- **WHEN** the app reads a `debug` option with `snapctl get` and only accepts `true` or `false`
- **THEN** the option is recorded with type `boolean`, not `string`

#### Scenario: App has no snap options
- **WHEN** nothing in the repository calls `snapctl get` and no option seeding is planned
- **THEN** `config_options` is absent or `[]` and `configure` is not listed for that reason
