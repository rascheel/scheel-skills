# Merged-/usr Detection and glibc Compatibility

Always run both checks **before Phase 2** (binary analysis delegation). They
identify structural issues that cause hard-to-debug runtime crashes if missed.

---

## 1c.1 — Merged-/usr detection

Modern Debian/Ubuntu images (Bookworm+, Ubuntu 24.04+) use a merged `/usr`
layout where `/bin`, `/lib`, and `/sbin` are symlinks to their `usr/`
counterparts.

```bash
[ -L rootfs/bin ] && echo "merged-/usr image" || echo "split-/usr image"
```

**If merged `/usr`:**
- `snap pack` does NOT follow symlinks for `command:` validation. Commands
  in `snapcraft.yaml` must use the `usr/bin/` path (e.g. `command: usr/bin/library_wrapper.sh`),
  not `bin/library_wrapper.sh`.
- `create_wrapper.sh` detects this automatically and places the wrapper at
  `usr/bin/library_wrapper.sh`. The `docker-to-snap` generator also detects
  merged-`/usr` at generation time and writes the correct `command:` path —
  no manual change needed if using the generated template.
- Watch for `stage collision` build errors where a part installs into `bin/`
  but the `bin → usr/bin` symlink is already in the stage directory.
- **`env-exporter-bash` part staging collision:** The `env-exporter-bash` part
  must stage its script to `usr/bin/env-exporter.sh` (not `bin/env-exporter.sh`)
  and the `command-chain:` must reference `usr/bin/env-exporter.sh`. On a
  merged-/usr image, `bin/` is a symlink staged by the `oci-container` part;
  staging a file into `bin/` from a different part creates a type conflict
  (symlink vs directory) that fails the build with:
  > `Parts 'oci-container' and 'env-exporter-bash' list the following files,
  > but with different contents or permissions: bin`

  The `docker-to-snap` template already uses `usr/bin/env-exporter.sh`; verify
  the generated `snapcraft.yaml` uses this path if you customise the template.

**If NOT merged `/usr` (split-`/usr` — Alpine Linux, RHEL/CentOS, older distros):**
- `/bin` is a real directory, not a symlink.
- `create_wrapper.sh` detects this and places the wrapper at `bin/library_wrapper.sh`.
- The `docker-to-snap` generator also detects split-`/usr` and writes
  `command: bin/library_wrapper.sh` in the generated `snapcraft.yaml`.
- **If you are working with a manually edited or pre-existing `snapcraft.yaml`**
  that was originally generated for a merged-`/usr` image and now targets a
  split-`/usr` image (or vice versa), you must update `command:` manually:
  ```yaml
  # split-/usr (Alpine, RHEL, etc.)
  command: bin/library_wrapper.sh
  # merged-/usr (Debian Bookworm+, Ubuntu 24.04+)
  command: usr/bin/library_wrapper.sh
  ```
- The build will succeed but `snap pack` will fail with:
  > `snap is unusable due to missing files: path "usr/bin/library_wrapper.sh" does not exist`
  if the `command:` path does not match the actual wrapper location.

---

## 1c.2 — glibc version compatibility check

When the OCI image's glibc version differs from the base snap's glibc version,
a subtle but fatal issue arises: **snapcraft automatically injects
`LD_LIBRARY_PATH` into `meta/snap.yaml`** pointing at the OCI image's libraries,
even when you never set it in `environment:`.

**Why this is dangerous:** The base snap shells (`/bin/sh`, `/bin/bash` from
core26/core24) run under this injected `LD_LIBRARY_PATH`. Everything that uses
these shells will crash with `GLIBC_X.Y not found` (SIGSEGV):
- Install/post-refresh/remove/configure **hooks** — `snapd` runs them with the
  base snap's `/bin/sh`, which inherits the injected path.
- **command-chain scripts** such as `env-exporter.sh` that have a `#!/bin/bash`
  shebang — also run under the base snap's bash.
- C binaries that call `popen()` or `system()` — these fork the base snap's
  `/bin/sh` at runtime.

**This means:** a snap using the `docker-to-snap` template with a glibc-mismatched
OCI image will fail at install time (`snap install`) with a confusing error:
> `run hook "install": /bin/sh: /snap/.../lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.XX' not found`

```bash
# Check OCI image glibc version (works on any architecture)
find rootfs -name "libc.so.6" -not -type l 2>/dev/null | head -1 | \
  xargs -I{} strings {} 2>/dev/null | grep -oP 'GLIBC_\K[0-9]+\.[0-9]+' | sort -V | tail -1

# Check host / core26 base glibc version
# Preferred: dpkg-query (works on all architectures on Ubuntu/Debian build hosts)
dpkg-query --showformat='${Version}' --show libc6 2>/dev/null | sed 's/-[^-]*$//'
# Fallback if dpkg-query is unavailable (x86-64 hosts only):
strings /lib/x86_64-linux-gnu/libc.so.6 2>/dev/null \
  | grep -oP 'GLIBC_\K[0-9]+\.[0-9]+' | sort -V | tail -1
```

**If versions differ — two-part fix:**

1. **Neutralise the auto-injected `LD_LIBRARY_PATH`** by explicitly setting it
   to empty in the global `environment:` block of `snapcraft.yaml`:
   ```yaml
   environment:
     LD_LIBRARY_PATH: ""
     env_alias: entrypoint
   ```
   The `docker-to-snap` generator detects a glibc mismatch and emits this line
   automatically. Do not remove it. Do not set any other value for
   `LD_LIBRARY_PATH` in global or per-app `environment:` blocks.

2. **Embed RPATH into all ELF executables** using the `embed_rpath.sh` build
   step, so the OCI app can find its own libraries without `LD_LIBRARY_PATH`.
   This step is included in the template's `override-build:` after
   `patch_interpreter.sh`. See `references/override-steps-guide.md §2` for the
   ET_EXEC-only RPATH rule.

Together, (1) prevents the base-snap shell crash and (2) ensures the OCI
application still finds its libraries.

The `docker-to-snap` script no longer attempts glibc version detection. The
generated `snapcraft.yaml` always includes `LD_LIBRARY_PATH: ""` unconditionally —
not only when a mismatch is detected — because the detection relied on host
tooling (`dpkg-query`, `strings`) that may be absent or return incorrect results
on non-Ubuntu or non-x86-64 build hosts. The unconditional setting is always safe:
when glibc versions match it is a no-op; when they differ it prevents the crash.
Combine it with the `embed_rpath.sh` build step to ensure ELF executables resolve
their libraries via embedded RPATH and do not need `LD_LIBRARY_PATH` at all.
