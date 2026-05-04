# Codebase Analysis Checklist for Snap Packaging

Work through each section. Record findings — they drive every decision in snapcraft.yaml.

---

## 1. Language and Runtime

- [ ] `go.mod` / `go.sum` present? → Go application
- [ ] `setup.py`, `pyproject.toml`, `requirements.txt`, or `*.py` entry point? → Python application (`plugin: python`; or `plugin: uv` if `uv.lock` is present, `plugin: poetry` if `[tool.poetry]` in pyproject.toml)
- [ ] `package.json`? → Node.js application
- [ ] `Cargo.toml`? → Rust application
- [ ] `Makefile`, `CMakeLists.txt`, or `meson.build`? → C/C++ application
- [ ] `configure.ac`, `Makefile.am`, `autogen.sh`, or `bootstrap`? → C/C++ autotools project
- [ ] `*.pro` file? → Qt/qmake application
- [ ] `pom.xml`? → Java/Maven application
- [ ] `build.gradle` or `build.gradle.kts`? → Java/Kotlin Gradle application
- [ ] `build.xml`? → Java Ant application
- [ ] `Gemfile` or `*.gemspec`? → Ruby application
- [ ] `SConstruct` or `SConscript`? → SCons build
- [ ] `*.csproj`, `*.fsproj`, or `*.sln`? → .NET/C# application
- [ ] `pubspec.yaml`? → Flutter/Dart application
- [ ] Pre-compiled binary already in repo? → `dump` plugin candidate
- [ ] Shell scripts only, no build step? → `dump` plugin (or `nil` with `cp` in `override-build` if files need transformation)
- [ ] What runtime version is required? (`.python-version`, `.nvmrc`, `go.mod go 1.X`, etc.)

---

## 2. Build System

Pick the plugin that fits the project's build. Either reach for the language plugin or write `override-build` with `nil` — whichever is cleaner for the codebase at hand:

| Build system | Language plugin | `nil` + `override-build` equivalent |
|---|---|---|
| `go.mod` | `plugin: go` | `go build -o $SNAPCRAFT_PART_INSTALL/bin/<name> ./...` |
| `setup.py` / `pyproject.toml` | `plugin: python` | `pip install . --prefix=$SNAPCRAFT_PART_INSTALL` |
| `pyproject.toml` (Poetry) | `plugin: poetry` (use `poetry-with` to include extra dependency groups) | `poetry export -f requirements.txt -o req.txt && pip install -r req.txt --prefix=$SNAPCRAFT_PART_INSTALL` |
| `uv.lock` (uv) | `plugin: uv` (installs venv directly into `$CRAFT_PART_INSTALL`; `UV_FROZEN=true` by default) | `uv sync --frozen && cp -r .venv $SNAPCRAFT_PART_INSTALL/` |
| `package.json` | `plugin: npm` | `npm ci && npm run build && cp -r dist $SNAPCRAFT_PART_INSTALL/...` |
| `Cargo.toml` | `plugin: rust` | `cargo build --release && install -Dm755 target/release/<name> $SNAPCRAFT_PART_INSTALL/bin/<name>` |
| `CMakeLists.txt` | `plugin: cmake` | `cmake -B build && cmake --build build && cmake --install build --prefix /` |
| `meson.build` | `plugin: meson` | `meson setup build && meson compile -C build && meson install -C build` |
| `Makefile` | `plugin: make` (requires `install` target + `DESTDIR` support) | `make && make install DESTDIR=$SNAPCRAFT_PART_INSTALL PREFIX=/` |
| `configure.ac` / `autogen.sh` | `plugin: autotools` (provides autoconf, automake, libtool) | `./configure && make && make install DESTDIR=$SNAPCRAFT_PART_INSTALL` |
| `*.pro` (Qt) | `plugin: qmake` (default Qt 5; set `qmake-major-version: 6` for Qt 6) | `qmake && make && make install DESTDIR=$SNAPCRAFT_PART_INSTALL` |
| `pom.xml` (Maven) | `plugin: maven` (add `maven` to `build-packages`; stage `default-jre-headless`; use `maven-use-wrapper: true` if project has `mvnw`) | `mvn package && install -Dm644 target/*.jar $SNAPCRAFT_PART_INSTALL/jar/` |
| `build.gradle` (Gradle) | `plugin: gradle` (stage `default-jre-headless`) | `gradle build && install -Dm644 build/libs/*.jar $SNAPCRAFT_PART_INSTALL/jar/` |
| `build.xml` (Ant) | `plugin: ant` (stage `default-jre-headless`; add `ant` to `build-packages`) | `ant && install -Dm644 *.jar $SNAPCRAFT_PART_INSTALL/jar/` |
| `Gemfile` (Ruby) | `plugin: ruby` (set `ruby-version`; optionally `ruby-use-bundler: true`) | `bundle install --path $SNAPCRAFT_PART_INSTALL` |
| `SConstruct` / `SConscript` | `plugin: scons` (add `scons` to `build-packages`) | `scons && scons install DESTDIR=$SNAPCRAFT_PART_INSTALL` |
| `*.csproj` / `*.sln` (.NET) | `plugin: dotnet` (provide `dotnet-sdk` snap or `dotnet8` build-package) | `dotnet publish -c Release -o $SNAPCRAFT_PART_INSTALL/bin` |
| `pubspec.yaml` (Flutter) | `plugin: flutter` (pulls Flutter from GitHub; set `flutter-channel`; defaults to `lib/main.dart` entry point) | n/a |
| Pre-compiled binary | (none — use `dump`) | n/a |
| Shell scripts only | (none — use `dump` or `nil`) | `install -Dm755 *.sh $SNAPCRAFT_PART_INSTALL/bin/` |

**Default to the language plugin when the project's build fits its conventions.** It handles toolchain setup, env vars, and install paths with less yaml. Switch to `nil` with `override-build` when the build is custom — multi-step pipelines, vendored toolchains, non-standard install layouts, or anything the plugin can't express cleanly. Don't contort yaml to fit a plugin when explicit shell would be clearer.

---

## 3. Entry Points

- [ ] What is the main executable name? (check `Makefile install` targets, `setup.py console_scripts`, `package.json bin`, README "Usage" section)
- [ ] Is there more than one binary? (each gets its own entry under `apps`)
- [ ] Does the binary need environment variables at runtime? (`environment:` in the app or part)
- [ ] Does it reference config files relative to `$HOME`? → will need layout or `$SNAP_USER_DATA`
- [ ] Does it reference config files in `/etc/<appname>`? → will need layout mapping

---

## 4. Service / Daemon Detection

- [ ] Systemd unit file (`*.service`) present in repo?
- [ ] Does the process stay in the foreground (`daemon: simple`) or fork and daemonize (`daemon: forking`)?
- [ ] Does it have a `--daemon` / `--no-daemon` / `--foreground` flag?
- [ ] README describes it as a server or background service?
- [ ] Does it need to start on boot? → `daemon: simple` or `daemon: forking` in apps entry

---

## 5. Desktop GUI Detection

- [ ] `.desktop` file present?
- [ ] Uses GTK (`gtk`, `gi.repository`, `libgtk`)? → `gtk-3-hermetic-extension` or stage gtk libs
- [ ] Uses Qt (`PyQt`, `PySide`, `libqt`)? → `kde-neon` extension or stage qt libs
- [ ] Renders OpenGL/Vulkan? → `opengl` plug
- [ ] Plays or records audio? → `audio-playback` / `audio-record` plugs
- [ ] Uses Wayland? → `wayland` plug
- [ ] Uses X11? → `x11` plug
- [ ] Uses D-Bus session bus? → `desktop` plug (grants session dbus access)

---

## 6. Network Access

- [ ] Opens TCP/UDP connections outbound (HTTP, WebSocket, gRPC, etc.)? → `network` plug
- [ ] Listens on a port? → `network-bind` plug
- [ ] Interacts with NetworkManager via D-Bus? → `network-manager` plug
- [ ] Manages firewall rules or raw sockets? → `network-control` plug

---

## 7. Filesystem Access

- [ ] Reads from `$HOME` or user directories? → `home` plug
- [ ] Reads/writes removable media (`/media`, `/mnt`, `/run/media`)? → `removable-media` plug
- [ ] Writes to `/etc/<appname>` (hardcoded path)? → use `layout` to remap to `$SNAP_DATA`
- [ ] Writes to `/var/lib/<appname>` (hardcoded path)? → use `layout` to remap to `$SNAP_DATA`
- [ ] Reads `/proc` or `/sys` for system info? → `system-observe` or `hardware-observe` plug
- [ ] Mounts filesystems? → `mount-observe` or may need `system-files`

---

## 8. Hardware and Device Access

Check source code, config files, and README for references to:

| Device pattern | Interface |
|---|---|
| `/dev/ttyS*`, `/dev/ttyUSB*`, `/dev/ttyACM*` | `serial-port` |
| Raw USB (`libusb`, `/dev/bus/usb`) | `raw-usb` |
| Bluetooth (`libbluetooth`, BlueZ D-Bus) | `bluetooth-control` |
| Camera/webcam (`/dev/video*`, V4L2) | `camera` |
| GPIO (`/sys/class/gpio`, `/dev/gpiomem`) | `gpio` |
| I2C (`/dev/i2c-*`) | `i2c` |
| SPI (`/dev/spidev*`) | `spi` |
| CUDA / GPU compute | `opengl` |

---

## 9. System Interaction

- [ ] Calls `setuid`/`setgid` or manages other processes? → `process-control` plug
- [ ] Uses `ptrace` (debugger, profiler)? → `ptrace` plug
- [ ] Reads hardware info (`dmidecode`, `lshw`, SMBIOS)? → `hardware-observe` plug
- [ ] Modifies network interfaces? → `network-control` plug
- [ ] Reads system logs (`/var/log`, `journalctl`)? → `log-observe` plug
- [ ] Uses `mount`/`umount`? → `mount-observe` (read) or `system-files` (write)
- [ ] Manages system time? → `time-control` plug

---

## 10. D-Bus Usage

- [ ] Connects to session D-Bus for desktop integration? → `desktop` plug covers most session D-Bus
- [ ] Connects to system D-Bus for a specific service?
  - `org.freedesktop.NetworkManager` → `network-manager` plug
  - `org.freedesktop.login1` → `login-session-observe` plug
  - `org.freedesktop.UDisks2` → `udisks2` plug
  - `org.freedesktop.hostname1` / `org.freedesktop.locale1` → `hostname-control` / `locale-control`
- [ ] Exposes its own D-Bus service? → needs `slots` section (or `dbus` interface slot)

---

## 11. Audio and Media

- [ ] Plays audio (PulseAudio, PipeWire, ALSA)? → `audio-playback` plug
- [ ] Records audio (microphone)? → `audio-record` plug
- [ ] Accesses webcam? → `camera` plug
- [ ] Decodes video (hardware-accelerated)? → `opengl` plug (for VA-API/VDPAU)

---

## 12. Location Services

- [ ] Requests GPS or geolocation data? → `location-observe` plug
- [ ] Manages location sources? → `location-control` plug

---

## 13. Dependencies and Staging

- [ ] What shared libraries does the binary link? (check `ldd output` if binary available, or `LDFLAGS` / `pkg-config` usage in build)
- [ ] Are there shared libraries that must be bundled? → add to `stage-packages` on the part
- [ ] Are there data files, icons, `.desktop` files, or config templates to include? → `override-build` copies them
- [ ] Does it need fonts? → `stage-packages: [fonts-*]` or `fontconfig` layout
- [ ] Does it need locale data? → `stage-packages: [locales]` + `LANG` environment variable
- [ ] Are there build-time-only tools (compilers, code generators)? → `build-packages` (not staged)
