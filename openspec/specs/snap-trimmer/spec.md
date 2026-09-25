# snap-trimmer Specification

## Purpose
Shrinks an already-built snap by editing `snapcraft.yaml`, never the `.snap` itself. It then rebuilds and checks that the app still works and no license files were lost. It runs on its own, outside the orchestrated pipeline.

## Requirements

### Requirement: Manifest-only changes
The skill SHALL make every size reduction through `snapcraft.yaml` edits. It MUST NOT edit, unpack-and-repack, or otherwise modify a `.snap` file. It SHALL keep a copy of the original `.snap` for comparison. In a git repository it MUST leave changes uncommitted and show a diff unless the user asks for a commit.

#### Scenario: Trim in a git repo
- **WHEN** the skill finishes trimming in a git working tree
- **THEN** the yaml changes are uncommitted and shown as a diff, and the original `.snap` is preserved

### Requirement: License files are never removed
The skill MUST NOT remove any license file (`copyright`, `LICENSE*`, `LICENCE*`, `COPYING*`, `COPYRIGHT*`, `NOTICE*`, `UNLICENSE*`) anywhere in the snap. Before removing a directory tree, it MUST relocate that tree's license files.

#### Scenario: Pruning documentation
- **WHEN** `usr/share/doc` is pruned
- **THEN** every `copyright` file under it is kept

#### Scenario: Removing a vendored source tree
- **WHEN** a build-only source tree containing `LICENSE` files is removed
- **THEN** its license files are relocated into the snap first

### Requirement: Extension and metadata files are preserved
The skill MUST NOT remove files injected by extensions, `snap/command-chain/**`, or `meta/**`.

#### Scenario: GNOME extension in use
- **WHEN** an app uses the `gnome` extension
- **THEN** files the extension injects remain in the trimmed snap

### Requirement: Cautious library removal
The skill MUST NOT remove a library flagged as unused by `snapcraft lint` if it looks like something loaded at runtime (for example graphics drivers, GStreamer, Qt or GTK modules, audio plugins, NSS or PAM modules). When unsure, it SHALL keep the library and say so in the report. Removing translations (`usr/share/locale`) MUST be left to the user.

#### Scenario: Lint flags a Mesa driver
- **WHEN** lint reports a library under `*/dri/*` as unused
- **THEN** the library is kept and the report explains why

### Requirement: Plan before editing
The skill SHALL present removal candidates grouped by category, with estimated savings, confidence (`safe`, `needs-verification` or `ask-user`) and the yaml mechanism for each. It MUST get confirmation before editing unless the user asked for fully autonomous operation, and MUST NOT combine safe cleanup and lint-flagged library removals into one unexplained change.

#### Scenario: Interactive run
- **WHEN** candidates are found and the user did not ask for autonomy
- **THEN** no yaml edit happens until the user confirms the plan

### Requirement: Base-correct overrides
Override steps the skill writes SHALL use the variables and default command for the manifest's `base`: `$SNAPCRAFT_PRIME` with `snapcraftctl prime` on core20, and `$CRAFT_PRIME` with `craftctl default` on core22, core24 and core26. It SHALL extend an existing cleanup part instead of adding a second one.

#### Scenario: core20 snap
- **WHEN** the manifest has `base: core20`
- **THEN** added prime overrides use `$SNAPCRAFT_PRIME` and `snapcraftctl prime`

### Requirement: Verified without regressions
After rebuilding, the skill SHALL compare the old and new snaps (size, file list, lint output) and check that every shared library dependency still resolves within the snap, its base or its content snaps. Any library that resolved before but not after MUST cause the responsible removal to be reverted. The skill SHALL smoke-test the app in a disposable LXD container, with `--classic` for classic snaps, and MUST NOT install it on the host.

#### Scenario: Removal breaks a library dependency
- **WHEN** a library dependency that resolved in the original snap no longer resolves
- **THEN** the removal that caused it is reverted

#### Scenario: No LXD available
- **WHEN** `lxc` is unavailable
- **THEN** the smoke test prints the exact manual commands instead of installing on the host

### Requirement: Broken lint environment detection
When `snapcraft lint` fails because the host's glibc does not match the mounted base snap, the skill SHALL say the lint environment is broken rather than the snap. It SHALL treat missing warnings as unknown rather than clean, and rely on the library-resolution check instead.

#### Scenario: GLIBC_PRIVATE symbol error during lint
- **WHEN** lint output contains `undefined symbol: __tunable_is_initialized`
- **THEN** the report says the lint host is broken and verification uses the library-resolution check

### Requirement: Report
The skill SHALL report compressed and uncompressed sizes before and after, savings per category, the exact yaml diff, a one-line reason for each remaining lint warning, and open decisions such as locale trimming or compression choice.

#### Scenario: Trim completes
- **WHEN** the rebuilt snap passes verification
- **THEN** the report includes before and after sizes and the yaml diff
