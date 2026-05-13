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

## Step 4: Write Results

### 4.1 Map each denial to its app

Identify which `apps:` entry in `snapcraft.yaml` caused each denial.

### 4.2 Write snap-validation-results.json

Write `snap-validation-results.json` to the project root using this schema:

```json
{
  "schema_version": "1.0",
  "snap_name": "<name>",
  "confinement": "<confinement>",
  "clean": false,
  "denials": [
    {
      "app": "<app-name>",
      "interface_suggestion": "<plug-name>",
      "raw_denial": "<full AppArmor/SecComp log line>"
    }
  ]
}
```

- Set `"clean": true` and `"denials": []` when no denials were found.
- Set `"interface_suggestion"` to the plug name from snappy-debug, or look up the denial
  in `references/denial-to-interface.md` if snappy-debug gives no suggestion.
- Write one denial object per unique `(app, interface_suggestion)` pair — deduplicate.

**Do not patch `snapcraft.yaml` or rebuild the snap.** The caller (or the
`snap-orchestrator` skill) is responsible for acting on the results.

---

## Step 5: Completion & Cleanup

### 5.1 Confirm clean run

A clean run is when all apps and daemons finish without producing any AppArmor/SecComp
denials. `snap-validation-results.json` will have `"clean": true`.

### 5.2 Present summary table

| App / Daemon | Denials Found | Plugs Suggested |
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
| No `.snap` file found | Write `snap-validation-results.json` with `"clean": false` and a note in `denials`; stop |
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
