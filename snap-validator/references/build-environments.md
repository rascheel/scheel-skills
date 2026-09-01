# Snap Build and Architecture Environments

Reference for selecting and using snap build environments during iterative development,
including the hand-off from cross-architecture builds to architecture-compatible
runtime validation.

---

## Environment 1: snapcraft + LXD backend (Recommended)

**Detection:** `which snapcraft && lxd version`

**Setup:**
```bash
lxd init --auto          # first time only
sudo usermod -aG lxd $USER && newgrp lxd   # first time only
```

Set `target_arch` before using any build command. For OCI conversions, use the
architecture normalized from the container metadata. For non-OCI snaps, derive it
from `snapcraft.yaml`, an existing snap filename, or explicit project/user
requirements. If the target architecture is unknown, stop before building.

**Usage:**
```bash
# First build (slow — LXD container is created and packages fetched)
snapcraft --use-lxd --build-for <target_arch>

# Subsequent builds (fast — container is reused, packages cached)
snapcraft --use-lxd --build-for <target_arch>

# Selective clean of a single part (does not destroy the container)
# NOTE: snapcraft clean does NOT accept --build-for in snapcraft 8/9 — omit it.
snapcraft clean <part-name> --use-lxd

# Full clean (destroys LXD container — resets all caches)
# NOTE: same — no --build-for on clean.
snapcraft clean --use-lxd

# Drop into build container for interactive debugging
snapcraft --use-lxd --build-for <target_arch> --shell         # before build steps
snapcraft --use-lxd --build-for <target_arch> --shell-after   # after build steps
```

**If `snapcraft clean` does not fully reset the LXD container state** (e.g. after
a partial manual clean that left inconsistent state), find and reset the container
directly:
```bash
# Find the build instance name
lxc list --all-projects | grep snapcraft-<snap-name>

# Manually remove the build artefacts inside the container
lxc exec --project snapcraft <instance-name> -- \
  rm -rf /root/parts /root/stage /root/prime
```

**Cross-architecture builds (amd64 host building arm64):**
```bash
snapcraft --use-lxd --build-for arm64
# Requires: sudo snap install qemu-user-static && sudo systemctl restart systemd-binfmt
```

`--build-for` is required for native and cross-architecture builds. Do not run a
plain `snapcraft --use-lxd` build; omitting `--build-for` can build for all
architectures instead of the single target architecture.

If any script executed by a part changes (for example a helper called from
`override-build:` or `override-prime:`), always run the selective clean for that
part before rebuilding. Snapcraft can otherwise reuse the previous staged copy of
the script from the part cache.

This only solves the **build** architecture. A snap built for `arm64` still needs
runtime validation in an environment that can execute `arm64` code. Choose that
environment from `references/install-and-verify.md` before installing or running
the snap.

**Pros:**
- Container is cached between runs — only the first build is slow
- `--shell` / `--shell-after` gives interactive access inside the build environment
- Selective `snapcraft clean <part>` resets only that part without destroying the container
- Kernel-shared (faster than VMs)

**Cons:**
- LXD setup required (group membership, `lxd init`)
- `snapcraft clean` (without a part name) destroys the container and all cached packages
- Networking conflicts possible with corporate VPNs or custom bridge configs
- Remote git sources (e.g. `snappy-env` part) are re-fetched on every full clean

**Key pain points:**
- Forgetting `--use-lxd` can cause snapcraft to use an unsupported non-LXD backend
- `snapcraft clean` (without a part name) nukes the LXD container — use `snapcraft clean <part-name> --use-lxd` for selective resets
- `snapcraft clean` does **not** accept `--build-for` in snapcraft 8/9 — the flag is only valid on `snapcraft` (build), not `clean`
- The `snappy-env` part fetches from GitHub on every container rebuild; pin with a local source override during heavy iteration:
  ```yaml
  env-exporter-bash:
    source: /path/to/local/snappy-env-clone
  ```

---

## Environment 2: Manual LXD container (persistent dev environment)

Use when you need to both build **and** install/test the snap in an isolated environment
without using the host.

**Setup (one-time):**
```bash
lxc launch ubuntu:24.04 snap-dev
lxc config set snap-dev security.nesting true
lxc restart snap-dev
lxc exec snap-dev -- snap install snapcraft --classic
lxc exec snap-dev -- lxd init --auto
```

**Transfer build output into the container:**
```bash
lxc file push myapp_1.0_amd64.snap snap-dev/home/ubuntu/
```

Or mount the build directory:
```bash
lxc config device add snap-dev project disk source=$(pwd) path=/home/ubuntu/project
```

**Build inside the container:**
```bash
lxc exec snap-dev -- bash -c "cd /home/ubuntu/project && snapcraft --use-lxd --build-for <target_arch>"
```

**Pros:**
- Fully isolated from host (both build and test happen inside the container)
- snapd runs natively inside the container (with `security.nesting=true`)
- Container persists between sessions — apt and pip caches survive
- `snap try prime/` works inside the container
- Install hooks, service lifecycle, and interface connections all work correctly

**Cons:**
- Manual setup and maintenance
- Nested snapd has some limitations: certain AppArmor profiles are more permissive than bare metal; a denial that shows on bare metal may not appear in nested LXD, and vice versa
- Port forwarding or host networking required to access networked services from the host

**Key pain points:**
- Container drift: manual package installs inside the container can cause environment inconsistency over time
- Some interfaces cannot be connected in nested containers (e.g. hardware interfaces)

---

## Cross-Architecture Runtime Hand-Off

After `snapcraft --use-lxd --build-for <arch>` succeeds, do **not** assume the
local LXD test container can run the result. Select a runtime validation route:

1. **Native target architecture — preferred:** use an LXD container on hardware
   matching the snap architecture.
2. **LXD remote on target hardware — preferred when local hardware differs:** add
   an LXD remote for a target-architecture machine and create the test container
   there.
3. **Full-system emulation — accepted for completion when snapd runs inside it:**
   use image-garden or an equivalent emulator to boot a target-architecture system,
   then run the normal devmode, strict, logs, connections, and `snappy-debug`
   validation workflow inside that system.
4. **QEMU/binfmt user-mode emulation — smoke tests only:** useful for early checks,
   but not equivalent to native or full-system validation because kernel, seccomp,
   AppArmor, performance, and hardware behavior can differ.

Host snapd is never a valid shortcut for any route.

### LXD remote pattern

```bash
lxc remote add <target-remote> <target-host>
lxc launch ubuntu:24.04 <target-remote>:snap-test
lxc config set <target-remote>:snap-test security.nesting true
lxc restart <target-remote>:snap-test
lxc exec <target-remote>:snap-test -- snap wait system seed.loaded
lxc file push myapp_1.0_<arch>.snap <target-remote>:snap-test/home/ubuntu/
```

Then use the install and verification commands from `references/install-and-verify.md`
inside that remote container.

---

## Build Environment Selection Decision Tree

```
Is snapcraft installed?
  NO → Install: sudo snap install snapcraft --classic
  YES ↓

Is LXD available? (lxd version succeeds)
  YES → Use Environment 1 with snapcraft --use-lxd --build-for <target_arch>
  NO  ↓

Attempt to set up LXD:
  sudo snap install lxd
  sudo lxd init --auto
  sudo usermod -aG lxd $USER && newgrp lxd
  lxd version  # confirm success
  SUCCESS → Use Environment 1 with snapcraft --use-lxd --build-for <target_arch>
  FAILURE → STOP. Report error. Do not proceed.
            "LXD is required. Host builds are not supported."

Is this a cross-architecture build? (target arch ≠ host arch)
  YES → Install QEMU user-static and build with --build-for:
        sudo snap install qemu-user-static
        sudo systemctl restart systemd-binfmt
        snapcraft --use-lxd --build-for <target_arch>
        THEN select an architecture-compatible runtime validation route.
  NO  → snapcraft --use-lxd --build-for <target_arch>
```

---

## Minimizing Rebuild Time

**Between iterative builds (don't full-clean unless necessary):**
```bash
# Only reset the part that changed
# NOTE: snapcraft clean does NOT accept --build-for — omit it.
snapcraft clean oci-container --use-lxd
snapcraft --use-lxd --build-for <target_arch>
```

This selective clean is mandatory after editing scripts that `oci-container` (or
any other part) runs during its lifecycle.

**Avoid re-downloading the snappy-env git source on every clean:**
```bash
# Clone locally once, point snapcraft at local clone during development
git clone https://github.com/canonical/snappy-env.git /tmp/snappy-env
# In snapcraft.yaml, temporarily change env-exporter-bash source to: /tmp/snappy-env
```

**Use `snap try prime/` for runtime-only changes** (see `references/install-and-verify.md`):
After a successful build, changes to wrapper scripts and environment can be tested
without rebuilding — modify `prime/` directly and `snap try prime/` again.
