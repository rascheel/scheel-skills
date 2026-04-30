# Codebase Analysis Checklist for Snap Packaging

Work through each section. Record findings — they drive every decision in snapcraft.yaml.

---

## 1. Language and Runtime

- [ ] `go.mod` / `go.sum` present? → Go application
- [ ] `setup.py`, `pyproject.toml`, `requirements.txt`, or `*.py` entry point? → Python application
- [ ] `package.json`? → Node.js application
- [ ] `Cargo.toml`? → Rust application
- [ ] `Makefile`, `CMakeLists.txt`, or `meson.build`? → C/C++ application
- [ ] Pre-compiled binary already in repo? → `dump` plugin candidate
- [ ] Shell scripts only, no build step? → `nil` plugin, `override-build` copies files
- [ ] What runtime version is required? (`.python-version`, `.nvmrc`, `go.mod go 1.X`, etc.)

---

## 2. Build System

Determine build steps so you can write `override-build`:

- [ ] `Makefile` → `make && make install DESTDIR=$SNAPCRAFT_PART_INSTALL`
- [ ] `CMakeLists.txt` → `cmake -B build && cmake --build build && cmake --install build --prefix /`
- [ ] `meson.build` → `meson setup build && meson compile -C build && meson install -C build`
- [ ] `setup.py` / `pyproject.toml` → `pip install . --prefix=$SNAPCRAFT_PART_INSTALL`
- [ ] `go.mod` → `go build -o $SNAPCRAFT_PART_INSTALL/bin/<name> ./...`
- [ ] `Cargo.toml` → `cargo build --release && install -Dm755 target/release/<name> $SNAPCRAFT_PART_INSTALL/bin/<name>`
- [ ] Pre-compiled binary → `dump` plugin with `source: .`
- [ ] No build (scripts only) → `nil` plugin, `override-build` with `cp` commands

**Always prefer `nil` plugin and write explicit shell commands in `override-build` over using language-specific plugins.**

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
