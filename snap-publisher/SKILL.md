---
name: snap-publisher
description: >
  Guides interactive publishing of snap packages to the Snap Store. Handles uploading new
  .snap files, registering snap names, releasing revisions to channels, and promoting
  existing revisions between channels. Operates hand-in-hand with the user, confirming
  every mutation before execution. Does NOT build snaps — assumes a .snap artifact already
  exists. WHEN: publish snap, upload snap to store, release snap, snap store upload,
  snapcraft upload, snapcraft release, promote snap revision, snap channel release,
  push snap to store, snap store publish, register snap name, snap store channel map.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.0.0"
  summary: "Interactively publishes, releases, and promotes snap packages to the Snap Store with user confirmation at every step."
  tags:
    - snap
    - snapcraft
    - publishing
    - canonical
    - linux
    - snap-store
---

# Snap Publisher

## Overview

Interactively publishes snap packages to the Snap Store (global or brand store).
Supports three workflows: uploading a new snap, releasing an uploaded revision to a
channel, and promoting an existing revision between channels. Every destructive or
publishing action requires explicit user confirmation.

> This skill does NOT build snaps. It expects a `.snap` file to already exist (e.g.,
> produced by the `snap-packager` skill or `snapcraft pack`).

## Workflow Decision Tree

Determine the user's goal:

1. **Uploading a new or updated .snap file?** → Follow §1 Upload & Release Workflow
2. **Promoting an existing revision to a new channel?** → Follow §2 Promotion Workflow

---

## §1 Upload & Release Workflow

### Step 1: Verify Authentication

Run:
```bash
snapcraft whoami
```

**If authentication fails:** Stop and instruct the user to run `snapcraft login` or
set the `SNAPCRAFT_STORE_CREDENTIALS` environment variable with a valid token.

**If authentication succeeds:** Note the account email and ID from the output.

**Discover available stores:** Instruct the user to run the following command
themselves (it will prompt for their password):
```
surl -p package_access -s production -e <their-email> -X GET \
  https://dashboard.snapcraft.io/dev/api/account > /tmp/snap-account.json
```

**Do NOT run this command yourself** — it requires interactive password entry.
Wait for the user to confirm they've run it.

Once the user confirms, parse the result:
```bash
jq -r '.stores[] | "\(.name) (ID: \(.id)) — roles: \(.roles | join(", "))"' /tmp/snap-account.json
```

This will output something like:
```
Global (ID: ubuntu) — roles: access
My Brand Store (ID: xK9mBn4pLqRs2wYz) — roles: view, access
Example Devices (ID: example-devices) — roles: access
```

Present this list to the user and ask which store they want to publish to.
The `ubuntu` store ID represents the global Snap Store.

**Note:** The user must have the `access` role in a store to upload/release to it.

Clean up after parsing:
```bash
rm -f /tmp/snap-account.json
```

If the user specifies a brand store, subsequent `snapcraft` commands will need the
token to be scoped to that store (via `SNAPCRAFT_STORE_CREDENTIALS`).

### Step 2: Inspect the .snap File

Identify the `.snap` file to upload. If the user hasn't specified one, look for `.snap`
files in the current directory and ask which one to use.

Extract metadata from the snap:
```bash
unsquashfs -p -cat <file>.snap snap.yaml
```

From `snap.yaml` inside the snap, note:
- **name** — the snap package name
- **version** — the version string
- **architectures** — target architecture(s)
- **confinement** — strict, classic, or devmode
- **grade** — stable or devel
- **base** — the base snap (e.g., core24)

Display this information to the user as a summary card before proceeding.

### Step 3: Registration Check

Check whether the snap name is already registered:
```bash
snapcraft status <snap-name> 2>&1
```

**If the snap is registered and the user owns it:** Proceed to Step 4.

**If the snap is NOT registered:**
1. Inform the user the name needs to be registered before uploading.
2. Ask if they want to register it now. Explain:
   - Registration claims the name globally (or in the scoped store).
   - Ask whether the snap should be **public** or **private**.
3. If confirmed:
   ```bash
   snapcraft register <snap-name> [--private]
   ```
4. If registration fails (name taken), inform the user and ask them to choose a
   different name or resolve the conflict manually.

**If confinement is `classic`:**
Stop and inform the user that classic confinement requires manual approval from the
Snap Store review team. See "Manual Step Instructions" section below for the template.

### Step 4: Review Current Channel Map

If the snap already exists in the store, show the current state:
```bash
snapcraft status <snap-name>
```

Display to the user:
- Which revisions are in which channels
- Which architectures are present
- The architecture of the `.snap` being uploaded

**If other architectures exist** for the same snap, mention this to the user (e.g.,
"Note: the store already has arm64 releases for this snap — this upload is amd64 only").

### Step 5: Select Target Channel

Ask the user which channel to release to. Provide guidance based on context:

**For a brand-new snap (no prior revisions):**
> "This is the first upload. Common practice is to release to `latest/edge` first for
> testing, then promote to `stable` once validated. Which channel would you like?"

**For an update to an existing snap:**
> "Current stable is revision N (vX.Y.Z). Which channel should this new revision go to?"

**Channel format:** `<track>/<risk>[/<branch>]`
- Tracks: `latest` (default), or named tracks (e.g., `24`, `2.x`)
- Risks: `stable`, `candidate`, `beta`, `edge`
- Branches: optional, time-limited (auto-expire after 30 days)

**If the user requests a track that doesn't exist:** Stop and inform them that track
creation requires a request to the store team (or store admin for brand stores). See
"Manual Step Instructions" section below.

### Step 6: Pre-flight Confirmation

Display a summary and ask for explicit confirmation:

```
┌─────────────────────────────────────┐
│ PUBLISH SUMMARY                     │
├─────────────────────────────────────┤
│ Snap:         <name>                │
│ Version:      <version>             │
│ Architecture: <arch>                │
│ Confinement:  <confinement>         │
│ Grade:        <grade>               │
│ File:         <filename.snap>       │
│ Store:        <store name or global>│
│ Channel:      <track/risk>          │
└─────────────────────────────────────┘
```

**Ask:** "Proceed with upload and release to `<channel>`?"

The user must explicitly confirm. If they decline, stop gracefully.

### Step 7: Upload

```bash
snapcraft upload <file>.snap
```

Report the result:
- Revision number assigned
- Any warnings from the store (e.g., manual review pending)

**If upload fails:** Report the error. Common issues:
- File too large → suggest checking snap size
- Duplicate upload → same binary already uploaded (show existing revision)
- Review required → inform user and explain the review process

### Step 8: Release

After successful upload, ask the user:

> "Upload succeeded — revision <N> created. Release revision <N> to `<channel>` now,
> or hold for later?"

**If the user confirms release:**
```bash
snapcraft release <snap-name> <revision> <channel>
```

**If the user wants to hold:** Inform them they can release later with:
```
snapcraft release <snap-name> <revision> <channel>
```

### Step 9: Post-Release Verification

After release, show the updated channel map:
```bash
snapcraft status <snap-name>
```

Confirm the revision appears in the expected channel. Report success.

---

## §2 Promotion Workflow

Use this workflow when the user wants to move an existing revision from one channel to
another (e.g., promote edge → stable) without uploading a new file.

### Step 1: Verify Authentication

Same as §1 Step 1.

### Step 2: Show Current Channel Map

```bash
snapcraft status <snap-name>
```

Display the full channel map to the user, highlighting:
- Which revisions are in which channels
- Architecture breakdown
- Any progressive releases in progress

### Step 3: Select Source and Target

Ask the user:
1. Which revision to promote (can specify by revision number or "whatever is in `<channel>`")
2. Which channel to promote it to

Provide guidance:
> "Typical promotion path: edge → beta → candidate → stable. Revision <N> (v<X.Y.Z>)
> is currently in `latest/edge`. Promote to which channel?"

### Step 4: Pre-flight Confirmation

Display summary:

```
┌─────────────────────────────────────┐
│ PROMOTION SUMMARY                   │
├─────────────────────────────────────┤
│ Snap:         <name>                │
│ Revision:     <rev>                 │
│ Version:      <version>             │
│ Architecture: <arch>                │
│ From:         <source-channel>      │
│ To:           <target-channel>      │
│ Store:        <store name or global>│
└─────────────────────────────────────┘
```

**Warn if promoting to stable:** "This will make revision <N> available to all users
on the stable channel. Confirm?"

### Step 5: Execute Promotion

```bash
snapcraft release <snap-name> <revision> <target-channel>
```

### Step 6: Post-Promotion Verification

Show updated channel map and confirm the promotion succeeded.

---

## Manual Step Instructions

When the skill encounters situations requiring manual user action, provide clear
instructions rather than attempting to automate:

### Classic Confinement Approval
```
⚠️  MANUAL STEP REQUIRED: Classic Confinement Approval

Your snap uses classic confinement, which requires store team approval.

1. Go to: https://forum.snapcraft.io/c/store-requests
2. Create a new topic with:
   - Title: "Classic confinement request: <snap-name>"
   - Body: Explain why your snap needs classic confinement
   - List the file system paths your snap accesses outside its sandbox
3. Wait for a reviewer to approve the request
4. Once approved, return here and re-run the publish workflow
```

### Track Creation
```
⚠️  MANUAL STEP REQUIRED: Track Creation

The track "<track-name>" does not exist for snap "<snap-name>".

1. Go to: https://forum.snapcraft.io/c/store-requests
2. Create a new topic requesting track creation:
   - Snap name: <name>
   - Requested track: <track-name>
   - Purpose: <why this track is needed>
   - Version pattern (optional): <regex for allowed versions>
3. A store admin will create the track
4. Once created, return here and release to <track>/<risk>
```

### Brand Store Snap Inclusion
```
⚠️  MANUAL STEP REQUIRED: Brand Store Inclusion

To publish "<snap-name>" in the brand store "<store-id>", a store admin must
first include the snap in the store's catalog.

Ask a store admin to run:
  POST /api/v2/stores/<store-id>/snaps
  {"add": [{"name": "<snap-name>"}]}

Or via surl:
  surl -a prod -X POST https://dashboard.snapcraft.io/api/v2/stores/<store-id>/snaps \
    -d '{"add": [{"name": "<snap-name>"}]}'

Once included, you can upload and release to this store.
```

---

## Key Rules

- **Never upload or release without explicit user confirmation**
- **Never use `--destructive-mode`** for any snapcraft operation
- Assume the `.snap` file already exists — do not attempt to build
- If `snapcraft whoami` fails, do not proceed — authentication is mandatory
- Classic confinement is a hard stop — cannot be automated
- Track creation is a hard stop — cannot be automated
- Always show the channel map before and after any release/promotion
- When multiple `.snap` files exist, ask the user which one to use
- Report architecture mismatches or gaps to the user
- For brand stores, auto-detect from token but always confirm with user

## Reference

For detailed information about the Snap Store channel model, tracks, and API:
→ Read `references/snap-store-publishing.md`
