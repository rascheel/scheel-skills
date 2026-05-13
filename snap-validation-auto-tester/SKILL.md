---
name: snap-validation-auto-tester
description: >
  Validates snap packages by provisioning a clean LXD container, installing the snap with
  --dangerous, running all declared CLI apps and daemons, and capturing AppArmor/SecComp
  denials via snappy-debug. Iteratively patches snapcraft.yaml with required interfaces
  based solely on observed runtime denials — never guesses. Hard-stops for classic
  confinement. Produces a summary table of apps checked, denials found, and plugs added.
  WHEN: validate snap interfaces, test snap in LXD, snap AppArmor denials, snap security
  testing, find snap plugs, snap confinement issues, snappy-debug scan, snap interface
  discovery, snap runtime testing, iterative snap patching, snap permissions audit,
  snapcraft.yaml interfaces, snap seccomp denial, snap access denied.
license: Apache-2.0
metadata:
  author: Canonical/platform-engineering
  version: "1.0.0"
  summary: Runs a snap in LXD, captures AppArmor/SecComp denials, and iteratively patches snapcraft.yaml with only the required interfaces.
  tags:
    - snap
    - snapcraft
    - lxd
    - security
    - validation
---

# Snap Validation Auto-Tester

Provisions a clean LXD container, installs the locally built snap, exercises every declared
app and daemon, captures AppArmor/SecComp denials with `snappy-debug`, and adds only the
plugs that are actually required. Classic-confinement snaps are excluded.

---

## Step 1: Discovery & Pre-Flight

### 1.1 Parse snapcraft.yaml

Read `snapcraft.yaml` directly and extract:

- `snap_name` — value of the top-level `name:` key
- `confinement` — value of the top-level `confinement:` key (default: `strict`)
- `apps` — for each entry under `apps:`, record `name`, `command`, and `daemon` (null if absent)

### 1.2 Classic confinement gate

**If `confinement: classic`:** Output the message below and **STOP immediately**.

> ⛔ This snap uses classic confinement. Classic snaps are excluded from this skill —
> they run without AppArmor mediation and interface-based patching does not apply.

### 1.3 Categorise apps

From the parsed output, split apps into two lists:

- **CLI apps** — entries where `daemon` is `null`
- **Daemons** — entries where `daemon` is `simple`, `forking`, or `notify`

---

## Step 2: Environment Setup

Provision a clean container and install prerequisites. Replace `<snap-file>` with the
actual `.snap` filename found in the working directory. If no `.snap` exists, ask the
user to build one first (`snapcraft`).

```bash
# Create container
lxc launch ubuntu:24.04 snap-test-env \
  -c security.nesting=true \
  -c security.privileged=false

# Wait for initialisation
lxc exec snap-test-env -- cloud-init status --wait

# Install required tools
lxc exec snap-test-env -- apt-get install -y squashfuse snappy-debug

# Transfer the snap
lxc file push <snap-file>.snap snap-test-env/tmp/<snap-file>.snap

# Install the snap (unsigned/local)
lxc exec snap-test-env -- snap install --dangerous /tmp/<snap-file>.snap
```

---

## Step 3: Execution & Monitoring Loop

Process each app in turn. Maintain a running denial log throughout.

### 3.1 CLI apps

```bash
# Start snappy-debug in the background
lxc exec snap-test-env -- snappy-debug &

# Run the app
lxc exec snap-test-env -- <snap-name>.<app-name>

# Collect AppArmor/SecComp lines
lxc exec snap-test-env -- journalctl -xe --no-pager | grep -iE "apparmor|seccomp"
```

### 3.2 Daemons

```bash
# Start the service
lxc exec snap-test-env -- snap start <snap-name>.<app-name>

# Stream logs while snappy-debug scans (30 s)
lxc exec snap-test-env -- journalctl -fu snap.<snap-name>.<app-name> --no-pager &
lxc exec snap-test-env -- snappy-debug --scan

# Collect denial lines
lxc exec snap-test-env -- journalctl -xe --no-pager | grep -iE "apparmor|seccomp"
```

### 3.3 Record each denial

For every denial captured, record:

1. **App name** — which app entry triggered it
2. **snappy-debug suggestion** — e.g., `suggested plug: network-bind`
3. **Raw AppArmor line** — for traceability in the summary

Consult `references/denial-to-interface.md` when snappy-debug gives no explicit
suggestion — it maps common denial patterns to the correct snap interface.

---

## Step 4: Iterative Patching

**Rule:** Only add plugs based on actual triggered denials. Never infer from source code.

### 4.1 Map denial to app

Identify which `apps:` entry in `snapcraft.yaml` caused the denial.

### 4.2 Patch snapcraft.yaml

Edit `snapcraft.yaml` directly to add the suggested plug to the identified app entry:

- Locate the `apps.<app-name>` section.
- If a `plugs:` list already exists, append the new plug name (skip if already present).
- If no `plugs:` key exists, add `plugs:` with the new plug as its first item.
- Preserve all existing comments and formatting in the file.
- This operation is idempotent — do not add a plug that is already listed.

### 4.3 Rebuild and retest automatically

After patching `snapcraft.yaml`, immediately rebuild and retest without user intervention:

```bash
# Rebuild the snap
snapcraft

# Identify the newly produced .snap file
ls -t *.snap | head -1
```

Then repeat the Step 2 install sequence (reuse the existing container or recreate it) and
re-run **only the apps that had denials**. Repeat Steps 3–4 until a full pass produces zero
new AppArmor/SecComp denials.

---

## Step 5: Completion & Cleanup

### 5.1 Confirm clean run

The session is complete when all apps and daemons finish their exercise without producing
new AppArmor/SecComp denials in `snappy-debug`.

### 5.2 Present summary table

| App / Daemon | Denials Found | Plugs Added |
|---|---|---|
| `<app-name>` | `<denial or "None">` | `<plug(s) or "None">` |

### 5.3 Cleanup — always execute

```bash
lxc delete --force snap-test-env
```

> ⚠️ Run this even if earlier steps failed.

---

## Error Handling

| Situation | Action |
|---|---|
| No `.snap` file found | Ask user to build first: `snapcraft` |
| LXD not installed or unavailable | Stop: "lxc is not available on this system" |
| `snap install` fails | Report exact error; do not continue |
| Denial with no snappy-debug suggestion | Read `references/denial-to-interface.md` |
| Container creation fails | Try `ubuntu:noble` as an alternative image |
| `cloud-init` times out | Wait 60 s and retry; if still failing, recreate container |

---

## Resources

| File | Purpose |
|---|---|
| `references/denial-to-interface.md` | Maps AppArmor denial patterns to snap interface names |
