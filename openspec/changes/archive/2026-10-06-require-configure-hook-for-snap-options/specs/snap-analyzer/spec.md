## ADDED Requirements

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

## MODIFIED Requirements

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
