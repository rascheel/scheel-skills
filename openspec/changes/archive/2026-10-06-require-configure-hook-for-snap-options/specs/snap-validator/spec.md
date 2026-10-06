## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Strict-mode denial capture
The skill SHALL run every CLI app and start every daemon declared in the manifest, and record each AppArmor or seccomp denial with its app, suggested interface and raw log line. Denials MUST be deduplicated per (app, interface) pair. When no interface is suggested by the tooling, the skill SHALL map the denial using its denial-to-interface reference. `clean` MUST be true only when no denials were captured and `diagnostics[]` is empty.

#### Scenario: Repeated denial
- **WHEN** the same app triggers the same `network-bind` denial three times
- **THEN** `denials[]` contains one entry for that app and interface

#### Scenario: No denials
- **WHEN** all apps and daemons run without denials and no diagnostic is recorded
- **THEN** results have `clean: true` and `denials: []`

### Requirement: Summary
The skill SHALL present a per-app table of denials and suggested plugs, and always report the devmode result, any store-review interfaces, and the snap option check result when one ran. In OCI mode it SHALL also report the test environment and reproducibility status.

#### Scenario: Clean run
- **WHEN** validation finishes with no denials
- **THEN** the summary shows "None" for each app and the devmode result

#### Scenario: Snap option check ran
- **WHEN** `config_check` is non-null
- **THEN** the summary states the key, the value set, whether it was a changed or re-applied value, and whether `snap set` succeeded and daemons stayed active, or why the check did not run
