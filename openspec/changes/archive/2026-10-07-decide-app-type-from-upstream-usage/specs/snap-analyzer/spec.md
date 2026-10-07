## ADDED Requirements

### Requirement: App type follows upstream usage
The skill SHALL decide each app's type from how upstream expects it to be run, and record that usage in `notes[]`. When each run takes arguments the user chooses, it SHALL ship a command app (`daemon: null`) whose command passes arguments through. It MUST add a service app only for a real signal: a bundled unit or init script, a documented service mode, a fixed startup config, or start-on-boot docs. A service-only snap MUST record why in `notes[]`.

#### Scenario: Server run on a chosen directory
- **WHEN** upstream's usage is `tool <path> [flags]` in the foreground and the repository has no unit file or service mode (for example darkhttpd or dufs)
- **THEN** `apps[]` has a command app with `daemon: null` whose command passes arguments through, no service app, and `notes[]` records the usage

#### Scenario: Command with a service mode
- **WHEN** upstream ships a user-facing command and a documented service mode such as `ollama serve`
- **THEN** `apps[]` has a command app named after the binary and a service app named `daemon`

#### Scenario: Pure service
- **WHEN** upstream is a foreground service that takes no arguments and reads only snap options (for example simple-server)
- **THEN** a service-only `apps[]` is allowed, and `notes[]` records why there is no command app

### Requirement: Plugs and options match the app type
The skill SHALL declare `home` or `removable-media` only for an app whose command can reach user-chosen paths. It MUST NOT record a snap option that nothing reads: an option needs the upstream code, or the wrapper of a service app justified under "App type follows upstream usage", to read it, and the reason SHALL be recorded in `notes[]`.

#### Scenario: Fixed-root service
- **WHEN** a service app serves only a fixed directory under `$SNAP_COMMON`
- **THEN** that app's `plugs` contain neither `home` nor `removable-media`

#### Scenario: Plain command
- **WHEN** the snap has only command apps and upstream never calls `snapctl`
- **THEN** `config_options` is absent or `[]`, and no `configure` hook is listed for snap options
