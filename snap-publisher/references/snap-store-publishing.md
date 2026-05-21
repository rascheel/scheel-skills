# Snap Store Publishing Reference

## Channel Model

The Snap Store uses a hierarchical channel system for releasing snaps:

```
<track>/<risk>/<branch>
```

### Tracks

Tracks represent major version lines or series of a snap. Every snap has a `latest`
track by default.

- `latest` — the default track, always exists
- Named tracks (e.g., `24`, `2.x`, `lts`) — must be created by a store admin
- Users install from the default track unless they explicitly specify one

**Track creation:** Requires a forum request or store admin action. Cannot be
automated by this skill.

### Risk Levels

Four risk levels exist within each track, from most stable to least:

| Risk | Purpose | Audience |
|------|---------|----------|
| `stable` | Production-ready releases | All users |
| `candidate` | Release candidates, final testing | Testers, early adopters |
| `beta` | Feature-complete but potentially buggy | Beta testers |
| `edge` | Latest development builds | Developers |

**Fallback behavior:** If a channel has no release, it falls back to the next-higher
risk level. For example, if nothing is released to `latest/candidate`, users on that
channel get whatever is in `latest/stable`.

### Branches

Branches are time-limited channels that automatically expire (default: 30 days).
Used for hotfixes or testing specific changes.

- Format: `<track>/<risk>/<branch-name>`
- Example: `latest/stable/hotfix-cve-2024-1234`
- Auto-closes after the expiration period

## Authentication

### snapcraft login

Interactive login using Ubuntu One SSO:
```bash
snapcraft login
```

### Environment Variable

For CI/CD or automated environments:
```bash
export SNAPCRAFT_STORE_CREDENTIALS="<exported-credentials>"
```

Export credentials with:
```bash
snapcraft export-login --snaps=<name> --channels=<channels> exported.txt
```

### Token Permissions

Tokens can be scoped with the following permissions relevant to publishing:

| Permission | Allows |
|------------|--------|
| `package_register` | Register new snap names |
| `package_upload` | Upload .snap files |
| `package_release` | Release revisions to channels |
| `package_access` | View snap details, channel maps |
| `package_update` | Update snap metadata |

Tokens can also be scoped to specific:
- **Snaps** (by name or snap_id)
- **Channels** (with fnmatch wildcards)
- **Store IDs** (for brand store operations)

### Checking Authentication

```bash
snapcraft whoami
```

Returns: account email, account ID, and permissions. Does NOT reveal brand store access.

### Discovering Store Access

`snapcraft whoami` does not list brand stores. To find available stores, instruct the
user to run:
```bash
surl -p package_access -s production -e <email> -X GET \
  https://dashboard.snapcraft.io/dev/api/account \
  | jq -r '.stores[] | "\(.name) (ID: \(.id)) — roles: \(.roles | join(", "))"'
```

This will prompt for the user's password and output a list like:
```
Global (ID: ubuntu) — roles: access
My Brand Store (ID: xK9mBn4pLqRs2wYz) — roles: view, access
Example Devices (ID: example-devices) — roles: access
```

- The `id` field is the store identifier needed for publishing operations
- `ubuntu` is the global Snap Store
- The user needs the `access` role to upload and release to a store

## Common snapcraft CLI Commands

### Register a Snap Name

```bash
snapcraft register <snap-name>
snapcraft register <snap-name> --private
```

- Claims the name in the global store (or store-scoped by token)
- `--private` makes the snap only visible to the publisher

### Upload a Snap

```bash
snapcraft upload <file>.snap
```

- Uploads the snap artifact to the store
- Returns a revision number
- Does NOT release to any channel (just stores the artifact)
- The store runs automated reviews on upload

### Release a Revision

```bash
snapcraft release <snap-name> <revision> <channel>
```

- Makes the specified revision available in the specified channel
- Can release the same revision to multiple channels
- This is also used for promotions (release existing rev to new channel)

### Check Status

```bash
snapcraft status <snap-name>
```

- Shows the full channel map
- Displays which revisions are in which channels
- Shows architecture breakdown

### List Revisions

```bash
snapcraft revisions <snap-name>
```

- Shows all uploaded revisions with their status
- Includes: revision number, version, arch, creation date

## Snap Store Review Process

### Automatic Reviews

Most snaps pass automatic review immediately upon upload. The automated review checks:
- Snap structure validity
- Security policy compliance for `strict` confinement
- Interface declarations match the snap's confinement

### Manual Review Required

Manual review is triggered by:
- **Classic confinement** — always requires manual approval
- **Certain interfaces** — some privileged interfaces need review
- **Store policy flags** — the store admin can require manual review

Status after upload:
- `Published` — passed automated review, released
- `ManualReviewPending` — waiting for human reviewer
- `NeedsInformation` — reviewer has questions
- `Rejected` — failed review (reasons provided)

## Brand Store Considerations

### Store-Scoped Tokens

When a token has `store_ids` attenuation, all operations (register, upload, release)
target that specific store. The `snapcraft whoami` output will show which store(s)
the token is scoped to.

### Snap Visibility in Brand Stores

Snaps in a brand store can come from:
1. **Registered directly** in the brand store
2. **Included** from the global store or allowed source stores (requires store_admin)
3. **Inherited** from parent stores (via store hierarchy)

### Publishing to a Brand Store

The publishing workflow (upload + release) is identical to the global store when
using a store-scoped token. The key difference is:
- The snap name must be registered in (or included into) the brand store
- Store-scoped tokens automatically target the correct store

## Error Reference

| Error | Meaning | Resolution |
|-------|---------|------------|
| `snap name already registered` | Someone else owns this name | Choose a different name or file a dispute |
| `permission denied` | Token lacks required permission | Re-login with broader permissions |
| `store_ids mismatch` | Token scoped to different store | Use correct token for target store |
| `revision already uploaded` | Same binary was uploaded before | Use existing revision number |
| `track does not exist` | Requested track hasn't been created | Request track creation via forum |
| `manual review required` | Snap needs human approval | Wait for review or address feedback |
| `classic not allowed` | Classic confinement not approved | File classic confinement request |
