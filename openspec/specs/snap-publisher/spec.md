# snap-publisher Specification

## Purpose
Walks the user through publishing an existing `.snap` to the Snap Store (global or brand store): registering the name, uploading, releasing to a channel, and promoting revisions between channels. The user confirms every change to the store. The skill does not build snaps.

## Requirements

### Requirement: No build responsibility
The skill SHALL work on an existing `.snap` file and MUST NOT build one. When several `.snap` files exist, it MUST ask which one to use.

#### Scenario: Two snap files present
- **WHEN** the directory holds `app_1.0_amd64.snap` and `app_1.0_arm64.snap`
- **THEN** the skill asks the user which file to publish

### Requirement: Authentication required
The skill SHALL check store authentication before any store operation and MUST stop if it fails, telling the user to log in or provide store credentials. It MUST NOT run commands that prompt for the user's password; it SHALL ask the user to run them and wait for confirmation. It SHALL delete temporary account data after reading it.

#### Scenario: Not logged in
- **WHEN** `snapcraft whoami` fails
- **THEN** the skill stops and tells the user to run `snapcraft login` or set `SNAPCRAFT_STORE_CREDENTIALS`

#### Scenario: Store discovery needs a password
- **WHEN** listing the user's stores requires an interactive password
- **THEN** the skill gives the user the command to run and waits for them to confirm

### Requirement: Explicit confirmation for every store change
The skill MUST NOT register a name, upload, release or promote without explicit user confirmation right before each action. Before uploading or promoting it SHALL show a summary of snap, version, architecture, confinement, grade, file, store and channel. Promotion to a `stable` channel MUST carry an additional warning that the revision will reach all stable users. If the user declines, the skill SHALL stop without changing the store.

#### Scenario: User declines upload
- **WHEN** the user declines at the publish summary
- **THEN** no upload or release is made

#### Scenario: Release after upload
- **WHEN** an upload succeeds
- **THEN** the skill asks whether to release the new revision now or hold it, and tells the user the release command if they hold

### Requirement: Name registration
When the snap name is not registered, the skill SHALL explain what registration claims, ask whether the snap should be public or private, and register only after confirmation. If the name is taken, it MUST ask the user to choose another name or resolve the conflict.

#### Scenario: Private registration
- **WHEN** the user confirms registration as private
- **THEN** the name is registered with `--private`

### Requirement: Stop for steps that cannot be automated
The skill MUST stop and give manual instructions when publishing needs classic-confinement approval, a track that does not exist, or brand-store inclusion of the snap.

#### Scenario: Classic snap
- **WHEN** the snap's confinement is `classic`
- **THEN** the skill stops and gives the user the store-request steps for classic approval

#### Scenario: Unknown track
- **WHEN** the user asks to release to track `3.x` and it does not exist
- **THEN** the skill stops and gives the user the track-creation request steps

### Requirement: Channel map shown around changes
The skill SHALL show the store's channel map before and after every release or promotion. It SHALL point out when the store has other architectures than the one being uploaded.

#### Scenario: Other architectures in the store
- **WHEN** the store has arm64 revisions and the upload is amd64
- **THEN** the skill tells the user before they confirm

### Requirement: No destructive build mode
The skill MUST NOT use `--destructive-mode` for any snapcraft command.

#### Scenario: Any snapcraft invocation
- **WHEN** the skill runs a snapcraft command
- **THEN** the command does not include `--destructive-mode`
