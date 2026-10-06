# snap-oci-analyzer Specification

## Purpose
Analyzes container input (a Docker Hub URL, an image reference, a `docker save` tarball, or a pre-extracted `config.json` plus `rootfs/`) and produces `snap-analysis.json` with an `oci` block of container-specific facts for `snapcraft-author` to use. It never writes snap artifacts or modifies the image.

## Requirements

### Requirement: Accepted input forms
The skill SHALL accept a Docker Hub URL or image reference, a `docker save` tarball, or a directory containing `config.json` and `rootfs/`. When none is present it MUST ask the user for one of them.

#### Scenario: Image reference
- **WHEN** the user provides `nginx:1.27`
- **THEN** the skill downloads it to a local docker-archive tarball without needing a Docker daemon, then extracts it

#### Scenario: Pre-extracted input
- **WHEN** `config.json` and `rootfs/` already exist
- **THEN** the skill skips download and extraction

#### Scenario: No input found
- **WHEN** there is no image reference, tarball, or extracted image
- **THEN** the skill asks the user which one to use

### Requirement: Dependencies checked before extraction
The skill SHALL check for its required tools (`tar`, `skopeo`, `umoci`, `jq`, and the Python YAML library) and attempt to install missing ones. If any remain unavailable it MUST report the exact error and stop before extracting.

#### Scenario: Install fails
- **WHEN** `skopeo` is missing and cannot be installed
- **THEN** the skill reports the installer's stderr and stops without writing an analysis

### Requirement: Facts only, never YAML
The skill MUST NOT create or modify `snapcraft.yaml`, including the `docker-to-snap` scaffold. Anything the recipe needs SHALL be recorded as facts in `snap-analysis.json`. When delegating binary analysis, it MUST use only the delegate's inference output and skip its manifest-patching step.

#### Scenario: Delegated analysis offers a patch step
- **WHEN** `analyze-binary-for-snapping` is invoked
- **THEN** its plug, layout and unmappable-path results are recorded in the analysis
- **AND** its snapcraft.yaml patching step is not run

### Requirement: Read-only rootfs
The skill MUST NOT write to, change permissions in, delete from, or otherwise modify anything inside `rootfs/`. Changes the image needs to build or run SHALL be recorded as `oci.overrides_needed[]` entries giving the part, phase, kind, target path and reason.

#### Scenario: Binary needs its ELF interpreter patched
- **WHEN** a binary's interpreter path must change to run inside the snap
- **THEN** an `overrides_needed[]` entry of kind `patch_interpreter` is recorded
- **AND** the binary under `rootfs/` is unchanged

### Requirement: Target architecture from image metadata
The skill SHALL derive `oci.target_arch` from the image's architecture metadata, mapping OCI/Go names to snapcraft names (for example `x86_64`→`amd64`, `aarch64`→`arm64`, `arm/v7`→`armhf`, `ppc64le`→`ppc64el`). If the architecture cannot be determined or is unsupported, it MUST stop without writing an analysis.

#### Scenario: arm64 image
- **WHEN** the image metadata reports `aarch64`
- **THEN** `oci.target_arch` is `arm64`

#### Scenario: Unknown architecture
- **WHEN** the metadata has no recognizable architecture
- **THEN** the skill reports the missing or unsupported value and writes no analysis

### Requirement: Daemon classification
The skill SHALL classify the entrypoint as a long-running service or a run-to-completion tool, extract with or without daemonization to match, and set `apps[].daemon` from that classification. It MUST state its reasoning and ask the user only when the classification is genuinely ambiguous.

#### Scenario: Web server image
- **WHEN** the entrypoint is a blocking network server
- **THEN** `apps[].daemon` is `"simple"` or `"forking"`

#### Scenario: Converter CLI image
- **WHEN** the entrypoint runs a task and exits
- **THEN** `apps[].daemon` is `null`

### Requirement: Container runtime facts
The skill SHALL detect and record, without applying any fix: whether the image uses a merged `/usr` (`oci.merged_usr`), glibc compatibility with the base snap (`oci.glibc_compat`, where the mitigation is `rpath_embed` or `none` and is never `LD_LIBRARY_PATH`), and, when the image runs as a non-root user, how that user is configured (`oci.system_usernames`).

#### Scenario: glibc mismatch
- **WHEN** the image's glibc version differs from the base snap's
- **THEN** `oci.glibc_compat.compatible` is false and `mitigation` is `rpath_embed`

#### Scenario: Root user image
- **WHEN** the image runs as uid 0
- **THEN** `oci.system_usernames.needed` is false

### Requirement: Content-sharing and operator-config facts
When two or more snaps must share a writable directory, the skill SHALL record provider and consumer roles in `oci.content_interfaces[]`. It SHALL record options that operators need to tune (ports, log levels, worker counts, TLS paths) in `oci.config_options[]`, and MUST NOT expose internal paths, data directories or debug flags as options.

#### Scenario: Single-snap deployment
- **WHEN** no directory is shared with another snap
- **THEN** `oci.content_interfaces` is empty

### Requirement: OCI analysis shape
The analysis SHALL have `schema_version: "1.1"`, `snap.base` equal to the `docker-to-snap` scaffold's `base:`, `snap.confinement: strict`, and `build.plugin: dump` with a local `rootfs/` source. `oci.reproducibility_baseline` MUST always be populated with the tarball path and the exact extraction command so the validator can replay extraction. Classic confinement MUST NOT be chosen unless the user insists, and then only through `snap-analyzer`'s classic warning flow.

#### Scenario: Scaffold uses core26
- **WHEN** the `docker-to-snap` scaffold declares `base: core26`
- **THEN** the analysis records `snap.base: core26`

#### Scenario: Analysis written after a tarball extraction
- **WHEN** the image was extracted from a tarball
- **THEN** `oci.reproducibility_baseline` records that tarball path and the exact `docker-to-snap` command used

### Requirement: Chat report
After writing the analysis, the skill SHALL report the full `/tmp` path, input type, target architecture, command path, interfaces (auto-connected and manual), counts and kinds of overrides, content interfaces, config options, non-root-user and glibc facts, and unmappable paths.

#### Scenario: Unmappable path found
- **WHEN** a path the image uses cannot be mapped to an interface or layout
- **THEN** it appears in `notes[]` with a reason and is named in the report
