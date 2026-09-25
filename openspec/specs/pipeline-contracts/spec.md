# pipeline-contracts Specification

## Purpose
Defines the file-based hand-off contracts between the snap pipeline skills: which skill writes and reads each artifact, where it lives, and how its schema evolves. The field-level shape is owned by the JSON Schemas under `schema/`; this spec covers the behavioral rules around them.

## Requirements

### Requirement: Analysis hand-off file
The pipeline SHALL exchange the packaging specification through a single `snap-analysis.json` file written to the project-scoped transient path `/tmp/snap-analysis-<dirname>.json`, where `<dirname>` is the basename of the project directory. Producers MUST NOT write it to the project root. Consumers MAY fall back to a legacy `./snap-analysis.json` when the `/tmp` path does not exist.

#### Scenario: Analyzer writes to the transient path
- **WHEN** either analyzer runs in a project directory named `myapp`
- **THEN** it writes the analysis to `/tmp/snap-analysis-myapp.json`
- **AND** no `snap-analysis.json` is created in the project root

#### Scenario: Consumer falls back to the legacy location
- **WHEN** `/tmp/snap-analysis-<dirname>.json` does not exist but `./snap-analysis.json` does
- **THEN** the consumer reads `./snap-analysis.json`

### Requirement: Two producers, one analysis contract
`snap-analyzer` (source code input) and `snap-oci-analyzer` (container input) SHALL both emit `snap-analysis.json` conforming to `schema/snap-analysis.schema.json`. Container input SHALL be marked solely by the presence of a top-level `oci` block; consumers MUST select OCI behavior from that key and not from which producer ran.

#### Scenario: OCI analysis is identified by its oci block
- **WHEN** a consumer reads an analysis that has a top-level `oci` key
- **THEN** it treats the input as a container image

#### Scenario: Source analysis has no oci block
- **WHEN** a consumer reads an analysis without an `oci` key
- **THEN** it treats the input as a source-code project, regardless of `schema_version`

### Requirement: Validation results file
The validator SHALL report results in `snap-validation-results.json` in the project root, conforming to `schema/snap-validation-results.schema.json`. Pre-flight failures that are not confinement denials MUST be reported as `diagnostics[]` entries with a machine-readable `code` and a human-readable `message`, and MUST NOT appear in `denials[]`.

#### Scenario: Missing snap artifact
- **WHEN** validation runs and no `.snap` file exists
- **THEN** `snap-validation-results.json` has `clean: false`, `denials: []`, and a `diagnostics[]` entry with code `missing-snap`

### Requirement: Single writer of the manifest
Within a pipeline run, `snap-packager` SHALL be the only skill that creates or modifies `snap/snapcraft.yaml`. Analyzers MUST record facts only, and the validator MUST only report.

#### Scenario: Validator finds a denial
- **WHEN** the validator observes a denial that needs a new plug
- **THEN** it records the suggestion in `snap-validation-results.json`
- **AND** `snap/snapcraft.yaml` is unchanged until `snap-packager` runs in patch mode

### Requirement: Additive schema evolution
Schema version bumps SHALL be additive: a new version MAY only add optional fields, so producers and consumers of an earlier version keep interoperating. Supported versions are `1.0`, `1.1` (adds the `oci` block) and `1.2` (adds top-level `target_arch`) for the analysis, and `1.0` and `1.1` for validation results.

#### Scenario: Consumer reads an older analysis
- **WHEN** `snap-packager` reads a schema `1.0` analysis
- **THEN** it packages the snap exactly as it would a `1.1` analysis that has no `oci` block

### Requirement: Single source of target architecture
An analysis SHALL carry at most one target architecture: `oci.target_arch` for container input, or top-level `target_arch` for a source build aimed at a non-host architecture. The two MUST NOT both be set. A null or absent value means build for the host architecture. Allowed values are `amd64`, `arm64`, `armhf`, `i386`, `ppc64el`, `s390x` and `riscv64`.

#### Scenario: Host-architecture source build
- **WHEN** a source analysis has `target_arch: null`
- **THEN** downstream skills build and test for the host architecture

#### Scenario: OCI analysis uses its own architecture field
- **WHEN** an analysis has an `oci` block
- **THEN** the effective target architecture is `oci.target_arch` and top-level `target_arch` is absent or null

#### Scenario: Both architecture fields set
- **WHEN** an analysis has an `oci` block and a non-null top-level `target_arch`
- **THEN** it fails validation against `schema/snap-analysis.schema.json`
- **AND** `schema/validate_contracts.py` rejects it with exit code `1`, with or without the `jsonschema` library

### Requirement: LXD-free contract gate
The repository SHALL provide `schema/validate_contracts.py`, which validates analysis and results files against the schemas without requiring `snapcraft` or LXD. It MUST exit `0` when all inputs are valid, `1` on a validation error, and `2` on a usage or file error. With `--self-test` it MUST validate the bundled examples in `schema/examples/`.

#### Scenario: Self-test passes on bundled examples
- **WHEN** `python3 schema/validate_contracts.py --self-test` is run
- **THEN** every bundled example validates and the exit code is `0`

#### Scenario: Works without the jsonschema library
- **WHEN** the `jsonschema` Python package is not installed
- **THEN** the gate falls back to its built-in structural checker and still reports pass or fail
