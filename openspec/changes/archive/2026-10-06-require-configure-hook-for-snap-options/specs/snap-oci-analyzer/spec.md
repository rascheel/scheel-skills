## MODIFIED Requirements

### Requirement: OCI analysis shape
The analysis SHALL have `schema_version: "1.3"`, `snap.base` equal to the `docker-to-snap` scaffold's `base:`, `snap.confinement: strict`, and `build.plugin: dump` with a local `rootfs/` source. Snap options SHALL go only in `oci.config_options[]`. `oci.reproducibility_baseline` MUST always hold the tarball path and exact extraction command. Classic confinement MUST NOT be chosen unless the user insists, and then only via `snap-analyzer`'s classic warning flow.

#### Scenario: Scaffold uses core26
- **WHEN** the `docker-to-snap` scaffold declares `base: core26`
- **THEN** the analysis records `snap.base: core26`

#### Scenario: Analysis written after a tarball extraction
- **WHEN** the image was extracted from a tarball
- **THEN** `oci.reproducibility_baseline` records that tarball path and the exact `docker-to-snap` command used

#### Scenario: Current schema version
- **WHEN** the analysis is written
- **THEN** its `schema_version` is `"1.3"` and it has no top-level `config_options`
