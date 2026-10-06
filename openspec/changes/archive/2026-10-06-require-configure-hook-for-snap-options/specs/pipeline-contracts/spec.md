## ADDED Requirements

### Requirement: Snap options require a configure hook
An analysis that records any snap option, in top-level `config_options[]` or in `oci.config_options[]`, MUST list `configure` in `hooks[]`, because snapd rejects every `snap set` on a snap without a `configure` hook. `schema/snap-analysis.schema.json` SHALL express this rule, and `schema/validate_contracts.py` MUST enforce it with or without the `jsonschema` library.

#### Scenario: Source analysis with options but no configure hook
- **WHEN** an analysis has a non-empty top-level `config_options[]` and `hooks: ["install"]`
- **THEN** it fails validation against `schema/snap-analysis.schema.json`
- **AND** `schema/validate_contracts.py` rejects it with exit code `1`, with or without the `jsonschema` library

#### Scenario: OCI analysis with options but no configure hook
- **WHEN** an analysis has a non-empty `oci.config_options[]` and `configure` is not in `hooks[]`
- **THEN** `schema/validate_contracts.py` rejects it with exit code `1`

#### Scenario: No snap options
- **WHEN** an analysis has no `config_options[]` and an empty or absent `oci.config_options[]`
- **THEN** the rule places no requirement on `hooks[]`

## MODIFIED Requirements

### Requirement: Validation results file
The validator SHALL report results in `snap-validation-results.json` in the project root, conforming to `schema/snap-validation-results.schema.json`. Failures that are not confinement denials, whether found before the snap runs (such as a missing `.snap`) or while exercising it (such as a rejected `snap set`), MUST be reported as `diagnostics[]` entries with a machine-readable `code` and a human-readable `message`, and MUST NOT appear in `denials[]`. Any diagnostic MUST make `clean` false.

#### Scenario: Missing snap artifact
- **WHEN** validation runs and no `.snap` file exists
- **THEN** `snap-validation-results.json` has `clean: false`, `denials: []`, and a `diagnostics[]` entry with code `missing-snap`

#### Scenario: snap set rejected
- **WHEN** the validator runs `snap set` on a snap whose analysis records snap options and snapd rejects it
- **THEN** `snap-validation-results.json` has `clean: false` and a `diagnostics[]` entry with code `config-set-failed` whose message contains snapd's error
- **AND** the failure does not appear in `denials[]`

### Requirement: Additive schema evolution
Schema version bumps SHALL be additive: a new version MAY only add optional fields, so earlier producers and consumers keep interoperating. Analysis versions are `1.0`, `1.1` (`oci` block), `1.2` (top-level `target_arch`) and `1.3` (top-level `config_options`); results versions are `1.0`, `1.1` and `1.2` (`config_check`). Producers SHALL write the current version (`1.3` analysis, `1.2` results) whatever fields they populate; consumers MUST accept every supported version.

#### Scenario: Consumer reads an older analysis
- **WHEN** `snapcraft-author` reads a schema `1.0` analysis
- **THEN** it packages the snap exactly as it would a `1.3` analysis that has no `oci` block, no `target_arch` and no `config_options`

#### Scenario: Host build from either analyzer
- **WHEN** either analyzer writes an analysis with no target architecture and no snap options
- **THEN** its `schema_version` is `"1.3"`

### Requirement: LXD-free contract gate
The repository SHALL provide `schema/validate_contracts.py`, which validates analysis and results files against the schemas without `snapcraft` or LXD. It MUST exit `0` when inputs are valid, `1` on a validation error, `2` on a usage or file error. With `--self-test` it MUST validate the bundled examples in `schema/examples/` and confirm that every instance in `schema/examples/invalid/` is rejected. With `--fallback` it SHALL use its built-in checker even when `jsonschema` is installed.

#### Scenario: Self-test passes on bundled examples
- **WHEN** `python3 schema/validate_contracts.py --self-test` is run
- **THEN** every bundled example validates, every invalid example is rejected, and the exit code is `0`

#### Scenario: Works without the jsonschema library
- **WHEN** the `jsonschema` Python package is not installed
- **THEN** the gate falls back to its built-in structural checker and still reports pass or fail

#### Scenario: Invalid example accepted
- **WHEN** an instance in `schema/examples/invalid/` passes validation
- **THEN** `--self-test` reports it as a failure and exits `1`
