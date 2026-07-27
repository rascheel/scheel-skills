# Snap Install, Run, and Verify Reference

Reference for installing a built snap, testing runtime behaviour, and iterating on confinement.

---

## Installation Methods

### Method A: `snap install --dangerous --devmode` (First Run)

Install the snap without confinement. Use this as the **first test** after every new snap build —
confirm the application runs correctly before fighting confinement issues.

```bash
snap install --dangerous --devmode myapp_1.0_amd64.snap
```

- AppArmor and seccomp are **fully bypassed** — the snap runs unconfined
- All interfaces are implicitly connected
- Service lifecycle hooks (`install`, `post-refresh`, `remove`, `configure`) run normally
- Daemons start automatically if declared as such in `snapcraft.yaml`

**Pass criteria:** Application starts, performs its function, and logs show no crashes.

---

### Method B: `snap install --dangerous` (Strict Confinement)

The production install path — strict confinement enforced.

```bash
snap install --dangerous myapp_1.0_amd64.snap
```

Use this after devmode confirms application correctness. Expect confinement denials
to appear in `snappy-debug` and `journalctl` output.

---

### Method C: `snap try prime/` (Fast Runtime Iteration)

Mount the `prime/` directory directly as an installed snap — **no repacking needed**.

```bash
# After a successful build, inside the project directory:
snap try prime/
snap restart myapp   # if daemon
```

Changes to files inside `prime/` are reflected immediately after restart.
This eliminates the squashfs pack + `snap install` cycle for runtime-only changes.

**What works with `snap try`:**
- Confinement is enforced (plugs and layouts apply)
- Service lifecycle and management work normally
- AppArmor and seccomp denials appear in logs

**What does NOT work with `snap try`:**
- `install` and `remove` hooks do **not** run — `/etc/hosts` is never written by hooks
- The squashfs compression is not tested (content is read from the bind-mounted directory)
- Subtle filesystem differences between prime and squashfs may be masked

**When to use:** After the build succeeds and you are tuning wrapper scripts, environment
variables (`library_wrapper.sh`, `env-exporter.sh`), or library paths — changes that
don't require modifying `snapcraft.yaml`.

---

### Method D: `snap refresh --dangerous` (Upgrade Path)

Test the upgrade path — triggers `post-refresh` hook instead of `install`.

```bash
# Snap must already be installed
snap refresh --dangerous myapp_1.1_amd64.snap
```

Important: this project implements `install` and `post-refresh` hooks separately.
Always test the refresh path in addition to fresh install — hook behaviour may diverge.

---

### Managing Existing Installations

```bash
snap remove myapp                # triggers remove hook (cleans /etc/hosts)
snap remove --purge myapp        # removes snap data as well
snap list                        # confirm installation state
snap services myapp              # view daemon status
```

---

## Where to Install (Test Environments)

Before installing, compare the snap architecture with the test environment
architecture:

```bash
dpkg --print-architecture
snap version | sed -n 's/^snapd //p'
```

If the snap file is named `myapp_1.0_arm64.snap`, the test environment must be
able to execute `arm64` code. Cross-building with `snapcraft --use-lxd --build-for`
does not make the local host a valid runtime environment.

Use this decision tree:

```
Does the local host architecture match the snap architecture?
  YES → Use Option 1: local LXD container.
  NO  ↓

Is target-architecture hardware available through an LXD remote?
  YES → Use Option 2: LXD remote on target hardware.
  NO  ↓

Can image-garden or equivalent full-system emulation boot the target architecture with snapd?
  YES → Use Option 3: full-system emulation. This can count as complete validation.
  NO  ↓

Can QEMU/binfmt run a target-architecture LXD container?
  YES → Use Option 4 for smoke testing only, then report that final validation still needs Option 2 or 3.
  NO  → STOP. Runtime validation cannot proceed for this architecture.
```

### Option 1: Local LXD Container with security.nesting=true

Use when the local host architecture matches the snap architecture. This is fully
isolated from the host. snapd, AppArmor, and seccomp all work inside the container.

**Setup (one-time):**
```bash
lxc launch ubuntu:24.04 snap-test
lxc config set snap-test security.nesting true
lxc restart snap-test
# Wait for snapd to start inside the container
lxc exec snap-test -- snap wait system seed.loaded
```

**Transfer and install the snap:**
```bash
lxc file push myapp_1.0_amd64.snap snap-test/home/ubuntu/
lxc exec snap-test -- snap install --dangerous --devmode /home/ubuntu/myapp_1.0_amd64.snap
```

**For `snap try prime/`, mount the project directory:**
```bash
lxc config device add snap-test project disk source=$(pwd) path=/home/ubuntu/project
lxc exec snap-test -- bash -c "cd /home/ubuntu/project && snap try prime/"
```

**Limitations:**
- Some AppArmor profiles are more permissive in nested LXD than on bare metal
- A denial visible on bare metal may not appear in nested LXD, and vice versa
- Hardware-facing interfaces (raw-usb, serial-port) cannot be meaningfully tested

**Pros:**
- Container `/etc/hosts` is isolated from the host — install hooks are safe to exercise
- snapd interface connections work normally
- `snappy-debug` works inside the container

---

### Option 2: LXD Remote on Target-Architecture Hardware

Use when the snap architecture differs from the local host and target-architecture
hardware is available elsewhere. This is the preferred final validation route for
cross-architecture snaps.

**Setup and install:**
```bash
lxc remote add <target-remote> <target-host>
lxc launch ubuntu:24.04 <target-remote>:snap-test
lxc config set <target-remote>:snap-test security.nesting true
lxc restart <target-remote>:snap-test
lxc exec <target-remote>:snap-test -- snap wait system seed.loaded
lxc file push myapp_1.0_<arch>.snap <target-remote>:snap-test/home/ubuntu/
lxc exec <target-remote>:snap-test -- snap install --dangerous --devmode /home/ubuntu/myapp_1.0_<arch>.snap
```

Run all devmode, strict, refresh, logs, connections, and `snappy-debug` checks
inside the remote LXD container.

---

### Option 3: Full-System Emulation (image-garden or equivalent)

Use when native target hardware is unavailable but a full target-architecture
system can be booted under image-garden or equivalent tooling. This route can
count as complete runtime validation if all of the following are true:

- The emulated system architecture matches the snap architecture.
- snapd runs inside the emulated system.
- The snap can be installed with `snap install --dangerous --devmode` and then
  reinstalled in strict mode.
- `snap logs`, `snap services`, `snap connections`, and `snappy-debug` are usable
  inside the emulated system.

Use the project-supported image-garden command to boot the target image, transfer
the snap into that system, and run the same commands used for local LXD validation:

```bash
snap install --dangerous --devmode /path/to/myapp_1.0_<arch>.snap
snap logs -f myapp.entrypoint
snap remove myapp
snap install --dangerous /path/to/myapp_1.0_<arch>.snap
sudo journalctl --output=short --follow --all | sudo snappy-debug
```

If snapd cannot run inside the emulated system, this option is not valid for
completion.

---

### Option 4: QEMU/binfmt LXD Smoke Test

Use only for early runtime smoke tests when neither target hardware nor full-system
emulation is immediately available. This route can catch obvious interpreter,
wrapper, and startup failures, but it does not replace Option 2 or Option 3 for
final validation.

**Setup example:**
```bash
sudo snap install qemu-user-static
sudo systemctl restart systemd-binfmt
lxc launch ubuntu:24.04/arm64 snap-test-arm64
lxc config set snap-test-arm64 security.nesting true
lxc restart snap-test-arm64
lxc exec snap-test-arm64 -- snap wait system seed.loaded
lxc file push myapp_1.0_arm64.snap snap-test-arm64/home/ubuntu/
lxc exec snap-test-arm64 -- snap install --dangerous --devmode /home/ubuntu/myapp_1.0_arm64.snap
```

**Limitations:**
- Kernel, seccomp, AppArmor, hardware access, and performance behavior may differ
  from target hardware.
- Some interfaces and daemons may fail for emulator-specific reasons.
- Treat successful results as smoke-test evidence only.

---

### Forbidden: Host with snapd

🚫 **The host snapd is NEVER an acceptable test environment.**

Installing snaps directly on the host risks polluting the host `/etc/hosts` and
other host resources, and produces unreliable confinement results. Use one of the
isolated routes above instead.

---

## Runtime Verification

### Check Service Status

```bash
snap services myapp                        # is the daemon running?
snap logs myapp.entrypoint                 # last few log lines
snap logs -n 100 myapp.entrypoint          # more lines
snap logs -f myapp.entrypoint              # follow (stream)
```

**ELF interpreter crash pattern:** If `patch_interpreter.sh` or the layout is wrong,
the service starts but immediately exits. In `snap logs`:
```
myapp.entrypoint[PID]: /snap/myapp/current/bin/library_wrapper.sh: line N: /snap/myapp/current/usr/bin/myapp: cannot execute: required file not found
```
Or simply no output at all after the service is reported as started. This is a
**build-time correctness issue** (not a confinement denial) — check the ELF interpreter
layout and the symlink created by `patch_interpreter.sh`.

### Inspect the Snap Environment Interactively

```bash
snap run --shell myapp.entrypoint
```

Inside the confined shell:
```bash
echo $SNAP                  # snap root path
echo $LD_LIBRARY_PATH       # verify library paths from create_wrapper.sh
echo $PATH                  # verify PATH from container metadata
ls $SNAP/usr/lib/myapp-ld-linux    # verify interpreter symlink exists
ldd $SNAP/usr/bin/myapp            # check dynamic linking
env | grep MY_VAR           # verify snappy-env variable injection
```

### Verify the Install Hook (`/etc/hosts`)

```bash
grep myservice /etc/hosts   # inside the test environment
```

If missing: `network-control` interface was not connected before install.
Connect it and reinstall:
```bash
snap connect myapp:network-control
snap remove myapp && snap install --dangerous myapp_1.0_amd64.snap
```

### Verify Interface Connections

```bash
snap connections myapp                    # all plugs and their connection state
snap connect myapp:home                   # manually connect a plug
snap disconnect myapp:raw-usb             # test without a specific plug
```

---

## Confinement Iteration Workflow

This is the iterative loop to go from devmode → strict confinement.

### Step 1: Install in devmode and confirm app works

Before installing, run a pre-flight check for common OCI-to-snap issues:

**Pre-devmode checklist:**
```bash
# 1. Check for LD_LIBRARY_PATH in snapcraft.yaml environment: blocks
#    This will contaminate base-snap subprocesses (popen/system) if glibc versions differ
grep -n "LD_LIBRARY_PATH" snap/snapcraft.yaml && \
  echo "⚠️  WARNING: LD_LIBRARY_PATH in snapcraft.yaml — remove it and use embed_rpath.sh instead"

# 2. Verify wrapper script does NOT export LD_LIBRARY_PATH as a shell variable
grep -n "export.*LD_LIBRARY_PATH\|LD_LIBRARY_PATH=.*export" prime/usr/bin/library_wrapper.sh 2>/dev/null && \
  echo "⚠️  WARNING: wrapper exports LD_LIBRARY_PATH — should be inline-only on the exec line"

# 3. Check snap command path for merged-/usr images
#    On Debian Bookworm+/Ubuntu 24.04+, bin/ is a symlink — command: must use usr/bin/
grep "command: bin/" snap/snapcraft.yaml && \
  echo "⚠️  WARNING: command uses bin/ path — use usr/bin/ for merged-/usr images"
```

```bash
snap install --dangerous --devmode myapp_1.0_amd64.snap
snap logs -f myapp.entrypoint   # confirm service starts and runs
```

**If the install hook crashes with SIGSEGV immediately:**
Check whether global `environment:` in `meta/snap.yaml` exports `LD_LIBRARY_PATH`
or `PATH`. These environment variables are injected by snapd for ALL processes in
the snap namespace — including the shell used to run the install hook itself.
If the base snap's shell inherits OCI glibc library paths, it will SIGSEGV on
startup before any hook code runs. Remove both from `environment:` blocks and rely
on RPATH embedding for library resolution.

**Install hook caveat — `/etc/passwd` inode problem (core26/core24 base):**
If the install hook creates a service user with `useradd`, that user may NOT be
visible to the snap daemon at runtime, even though `useradd` succeeds. This is
because:

1. The snap namespace sets up a `tmpfs` at `/etc` and bind-mounts `/etc/passwd`
   capturing the file's INODE at namespace setup time.
2. `useradd` atomically replaces `/etc/passwd` via `rename()`, creating a NEW inode.
3. All snap processes (including the daemon) see the OLD inode — the one without
   the new user.

**Symptom:** `find -user <serviceuser>` or `id <serviceuser>` returns "invalid user"
inside the snap, even though `getent passwd <serviceuser>` works on the host.

**Fix:** Use `libnss_wrapper.so` with a writable temp copy of `/etc/passwd`
populated from the OCI image's own `/etc/passwd` (which already has the service
user). See `snap-oci-container/references/system-usernames-guide.md §9` for full details.

### Step 2: Observe denials with snappy-debug

In **terminal 1** (inside the test environment):
```bash
snap install snappy-debug
sudo journalctl --output=short --follow --all | sudo snappy-debug
```

In **terminal 2**: exercise all application code paths — trigger every feature,
endpoint, or operation the application supports.

`snappy-debug` translates raw AppArmor denial log lines into suggested snap interface names:
```
= AppArmor =
File missing: /proc/1/status        → system-observe
Network access: tcp 0.0.0.0:8080    → network-bind
```

### Step 3: Add plugs to snapcraft.yaml and rebuild

```yaml
apps:
  entrypoint:
    plugs:
      - home
      - network
      - network-bind
      - system-observe
      # add new plugs here
```

Rebuild:
```bash
snapcraft clean oci-container --use-lxd --build-for <target_arch>   # reset only the affected part
snapcraft --use-lxd --build-for <target_arch>
```

If the change touched a script run by the part, the selective clean is mandatory;
without it, Snapcraft may rebuild with the old cached script.

### Step 4: Install in strict mode and re-test

> **All snap install and test commands in this section run inside the selected isolated
> test environment, not on the host.** See "Where to Install (Test Environments)" for setup.

```bash
# Inside the LXD container (lxc exec snap-test -- bash):
snap remove myapp
snap install --dangerous myapp_1.0_amd64.snap   # no --devmode
snap logs -f myapp.entrypoint
sudo journalctl --output=short --follow --all | sudo snappy-debug
```

Repeat steps 3–4 until `snappy-debug` shows no denials during normal operation.

### Step 5: Handle layouts for hardcoded paths

If the application accesses an absolute path outside `$SNAP` that isn't covered by
a plug, add a layout:

```yaml
layout:
  /etc/myapp:
    bind: $SNAP_COMMON/etc/myapp    # writable directory
  /var/lib/myapp:
    bind: $SNAP_COMMON/var/lib/myapp
  /usr/share/myapp:
    symlink: $SNAP/usr/share/myapp  # read-only resource
```

### Step 6: Identify store-review-only interfaces early

Some interfaces require manual review by the Snap Store team and cannot be
self-connected. Identify these early to avoid surprises at upload time.

Common store-review-only interfaces:
- `snapd-control`
- `system-files` (writing to arbitrary host paths)
- `docker-support`
- `kubernetes-support`

If your snap needs these, plan for store review time in your release schedule.

---

## Quick Verification Checklist

After each build+install cycle, check:

- [ ] `snap services myapp` → service is `active (running)`
- [ ] `snap logs myapp.entrypoint` → no crash or exec errors
- [ ] `grep myservice /etc/hosts` → install hook wrote the entry (if applicable)
- [ ] `snap connections myapp` → expected plugs are connected
- [ ] `snap run --shell myapp.entrypoint` → `$LD_LIBRARY_PATH` and `$PATH` are correct
- [ ] No denials in `snappy-debug` during normal operation (for strict installs)
- [ ] `snap refresh --dangerous myapp_1.1_amd64.snap` → post-refresh hook works
