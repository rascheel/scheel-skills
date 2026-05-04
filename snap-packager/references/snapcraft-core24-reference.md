# Snapcraft core24 Reference (Snapcraft 8.x)

## Top-Level Fields

```yaml
name: my-app               # snap name: lowercase, hyphens, max 40 chars
base: core24               # ALWAYS core24
# build-base: only set this when base: bare (omit it when base: core24)
version: '1.0.0'           # semver or 'git' (resolved at build time)
title: My App              # lint warning if absent; human-readable display name
summary: One-line summary  # max 79 chars
description: |
  Multi-line description.
# license: GPL-2.0-or-later  # lint warning if absent; only add when the
#                             # packaged app's license is unambiguous from
#                             # the codebase (source headers, COPYING file, etc.)
# contact: https://...       # lint warning if absent
# issues: https://...        # lint info if absent
# source-code: https://...   # lint info if absent
grade: stable              # stable | devel
confinement: strict        # strict | classic | devmode (devmode = testing only)

# Optional top-level plugs (shared across all apps):
plugs:
  network:
  home:

# Optional top-level slots (for D-Bus services the snap exposes):
slots:
  my-dbus-service:
    interface: dbus
    bus: session
    name: com.example.MyApp
```

---

## Apps Section

Each binary or service the snap exposes is an `apps` entry.

```yaml
apps:
  my-app:
    command: bin/my-app          # path relative to $SNAP
    plugs:                       # interfaces this app needs
      - network
      - home
    environment:
      MY_VAR: "value"

  my-daemon:
    command: bin/my-daemon
    daemon: simple               # simple | forking | oneshot | notify
    restart-condition: always    # always | on-failure | on-abnormal | never
    stop-command: bin/my-daemon --stop   # optional graceful stop
    plugs:
      - network-bind
```

**Daemon types:**
- `simple` — process stays in foreground; snapd tracks it directly
- `forking` — process calls `fork()` and the parent exits; snapd tracks the child
- `oneshot` — runs once and exits; snapd considers it healthy on exit 0
- `notify` — uses `sd_notify` to signal readiness

---

## Parts Section

### nil Plugin

Use when the build is custom enough that a language plugin would require contortions — multi-step pipelines, vendored toolchains, non-standard install layouts. Write all build steps yourself in `override-build`.

```yaml
parts:
  my-app:
    plugin: nil
    source: .
    build-packages:
      - build-essential
      - libssl-dev
    stage-packages:
      - libssl3
    override-build: |
      # Example: Go app
      go build -o $SNAPCRAFT_PART_INSTALL/bin/my-app ./cmd/my-app

      # Example: Make-based app
      make
      make install DESTDIR=$SNAPCRAFT_PART_INSTALL PREFIX=/

      # Example: Python app
      pip install . --prefix=$SNAPCRAFT_PART_INSTALL

      # Example: copy scripts
      install -Dm755 my-script.sh $SNAPCRAFT_PART_INSTALL/bin/my-script
```

**Key environment variables available in override-build:**
- `$SNAPCRAFT_PART_INSTALL` — destination dir; install everything here
- `$SNAPCRAFT_PART_SRC` — unpacked source directory
- `$SNAPCRAFT_PART_BUILD` — build working directory
- `$SNAPCRAFT_PROJECT_DIR` — project root
- `$SNAPCRAFT_STAGE` — staging area (read from other parts' output)

### dump Plugin

Use for pre-built binaries or when the snap is just a collection of files.

```yaml
parts:
  my-app:
    plugin: dump
    source: .                  # or a URL, or a local path
    source-type: local         # local | git | tar | zip | deb | rpm
    stage:
      - bin/
      - lib/
      - share/
    prime:
      - bin/
      - lib/
```

### Language Plugins

Prefer these when the project's build fits the plugin's conventions — they handle toolchain setup, environment variables, and install paths with less yaml than a hand-written `nil` build.

**go:**
```yaml
parts:
  my-app:
    plugin: go
    source: .
    build-snaps:
      - go/1.22/stable
```

**python:**
```yaml
parts:
  my-app:
    plugin: python
    source: .
    python-packages:
      - requests
    stage-packages:
      - python3
```

**node:**
```yaml
parts:
  my-app:
    plugin: npm
    source: .
    npm-node-version: '20.11.0'
```

**cmake:**
```yaml
parts:
  my-app:
    plugin: cmake
    source: .
    cmake-parameters:
      - -DCMAKE_INSTALL_PREFIX=/
    build-packages:
      - cmake
      - build-essential
```

---

## Layouts

Use layouts when an app hardcodes paths that are inaccessible under strict confinement.

**Off-limits paths — layouts are rejected for these prefixes:**
`/var/run`, `/run`, `/proc`, `/sys`, `/dev`, `/boot`, `/lib`, `/lib64`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/lib`. Do not attempt to layout files under these paths — snap will refuse to pack. For pidfiles under `/var/run`, omit the layout entirely and pass an explicit `--pidfile $SNAP_DATA/...` flag to the daemon command instead.

```yaml
layout:
  /etc/my-app:
    bind: $SNAP_DATA/etc/my-app     # writable, persists across updates
  /var/lib/my-app:
    bind: $SNAP_DATA/var/lib/my-app
  /usr/share/my-app:
    bind: $SNAP/usr/share/my-app    # read-only from snap package
  /tmp/my-app:
    bind: $XDG_RUNTIME_DIR/my-app   # ephemeral
```

**Path variables:**
- `$SNAP` — read-only snap package contents
- `$SNAP_DATA` — writable, persists across updates (`/var/snap/<name>/current`)
- `$SNAP_COMMON` — writable, shared across snap versions (`/var/snap/<name>/common`)
- `$SNAP_USER_DATA` — per-user writable, versioned (`~/snap/<name>/current`)
- `$SNAP_USER_COMMON` — per-user writable, shared across versions

---

## Extensions (for Desktop Apps)

Extensions auto-configure plugs, environment, and stage packages for common desktop stacks.

```yaml
apps:
  my-gui-app:
    command: bin/my-app
    extensions:
      - gnome              # GTK4 + GNOME libraries via content snap
      # OR
      - kde-neon           # Qt5/Qt6 + KDE libraries via content snap
```

Using an extension is usually preferable to manually staging GTK or Qt — it reduces snap size significantly.

---

## Stage vs Prime

- `stage` — files copied to the staging area (used by dependent parts); include everything needed for linking
- `prime` — files included in the final snap; exclude dev headers, static libs, build artifacts

```yaml
parts:
  my-app:
    plugin: nil
    source: .
    override-build: |
      make install DESTDIR=$SNAPCRAFT_PART_INSTALL
    stage:
      - bin/
      - lib/
      - share/
    prime:
      - bin/my-app          # include only the binary in the final snap
      - -lib/*.a            # exclude static libs (prefix with - to exclude)
```

---

## Common stage-packages

| Need | Package |
|------|---------|
| TLS / HTTPS | `libssl3`, `ca-certificates` |
| DNS resolution | `libnss-resolve` or `libc6` (usually included via base) |
| ICU / Unicode | `libicu74` |
| Zlib | `zlib1g` |
| SQLite | `libsqlite3-0` |
| GTK3 | use `gnome` extension instead |
| Qt5 | use `kde-neon` extension instead |
| Python 3 | `python3`, `python3-distutils` |
| curl/libcurl | `libcurl4` |

---

## Full Minimal Example

```yaml
name: my-tool
base: core24
build-base: core24
version: '0.1.0'
summary: A minimal CLI tool
description: |
  Does something useful from the command line.
grade: stable
confinement: strict

apps:
  my-tool:
    command: bin/my-tool
    plugs:
      - network
      - home

parts:
  my-tool:
    plugin: nil
    source: .
    build-packages:
      - build-essential
    override-build: |
      make
      install -Dm755 my-tool $SNAPCRAFT_PART_INSTALL/bin/my-tool
```
