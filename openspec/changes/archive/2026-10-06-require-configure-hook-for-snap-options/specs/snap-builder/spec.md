## ADDED Requirements

### Requirement: Snap options in the final report
For every snap option the final report SHALL give a `snap set` example and the validator's option check status: passed (value changed or re-applied), not run (with the reason), or failed. The report MUST NOT describe the snap as configurable through `snap set` unless `config_check` has `checked`, `set_ok` and `daemons_active` all true.

#### Scenario: Option check not run
- **WHEN** `config_check.checked` is false
- **THEN** the report lists the `snap set` keys, says they were not tested and why, and does not claim the snap is configurable

## MODIFIED Requirements

### Requirement: Result-driven loop routing
After each validation run the skill SHALL route on the results in this order:
1. Non-empty `diagnostics[]` stops the pipeline and reports them. This includes non-denial failures found while exercising the snap, such as `config-set-failed`.
2. `devmode_pass: false` sends the snap to snapcraft-author's build-fix branch.
3. `clean: true` ends the denial loop.
4. Remaining denials send the snap to snapcraft-author's patch mode.

After every patch or fix it SHALL rebuild and validate again.

#### Scenario: Devmode failure
- **WHEN** results have `devmode_pass: false`
- **THEN** snapcraft-author is asked for a build fix, not a plug or layout patch, and the denial counter is not incremented

#### Scenario: Diagnostics reported
- **WHEN** results contain diagnostics
- **THEN** the pipeline stops and shows each diagnostic

#### Scenario: snap set rejected
- **WHEN** results contain a `config-set-failed` diagnostic
- **THEN** the pipeline stops, shows snapd's error, and does not send the snap to patch mode

### Requirement: Final report
The skill SHALL report:
- snap name, analyzer used, confinement, plugin and target architecture
- iteration counts, devmode status, store-review interfaces and reproducibility status
- the files produced
- the exact `snap connect` command for every interface with `auto_connected: false`
- every snap option with a `snap set` example (see "Snap options in the final report")
- any unresolved denials or reproducibility diffs

#### Scenario: Store-review interface needed
- **WHEN** results list `docker-support` in `store_review_interfaces[]`
- **THEN** the report warns that the snap needs manual Snap Store review before distribution
