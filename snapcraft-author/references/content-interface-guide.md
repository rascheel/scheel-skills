# Content Interface Guide: Cross-Snap File Sharing

Use this guide when two or more snaps need to share a writable directory — for
example, a certificate manager writing to `/etc/letsencrypt` and a web server
reading those certificates, or any producer/consumer pair that shares runtime
data across snap boundaries.

---

## When to Use the Content Interface vs a Layout

| Requirement | Use |
|---|---|
| Path is hardcoded in the app; data lives entirely inside this snap | `layout:` |
| Path is shared with **another snap** (different snap name) | `content` interface |
| Path must be writable by one snap and readable by another | `content` interface |
| Path is operator-provisioned at runtime (certs, configs) but only used by this snap | `layout: bind: $SNAP_COMMON/<subpath>` |

**Do not combine a layout and a content interface target for the same path.**
See the [Double-Bind Warning](#double-bind-warning) below.

---

## Roles

| Role | Snap | Key | What it does |
|---|---|---|---|
| Provider (slot) | The snap that **owns and writes** the shared data | `slots:` | Exposes its `$SNAP_COMMON/<subpath>` to other snaps |
| Consumer (plug) | The snap that **reads or writes** the shared data | `plugs:` | Receives a bind-mount of the provider's directory at its own `$SNAP_COMMON/<subpath>` |

---

## Provider Snap — Defining a Content Slot

```yaml
slots:
  my-data:
    interface: content
    content: my-data          # arbitrary label — must match the plug's content: value
    write:
      - $SNAP_COMMON/shared   # the directory to expose; must be under $SNAP_COMMON
                              # (use read: instead of write: to expose read-only)
```

- `write:` grants the consumer read-write access.
- `read:` grants the consumer read-only access.
- The directory under `$SNAP_COMMON` is created by the provider's install hook.
- The provider's own layouts can still map the path into the classic location
  (e.g. `/etc/letsencrypt → $SNAP_COMMON/letsencrypt`). See the Double-Bind
  Warning below before doing this.

---

## Consumer Snap — Defining a Content Plug

```yaml
plugs:
  my-data:
    interface: content
    content: my-data          # must match the provider slot's content: value
    target: $SNAP_COMMON/shared  # where to mount the provider's directory
                                 # inside THIS snap's namespace

apps:
  entrypoint:
    plugs:
      - my-data               # declare the plug on the app to enable it
```

- `target` must be a path under `$SNAP_COMMON` or `$SNAP_DATA`.
- Do **not** set `default-provider` when building inside LXD. Snapcraft will
  attempt to install the named provider snap into the LXD build container,
  which will fail if the snap is not published on the store:
  ```
  'my-provider' does not exist or is not available on channel 'latest/stable'.
  ```
  Connect the plug manually after install instead (see [Connecting](#connecting)).
- The `target` directory is empty until the content interface is connected.
  The consumer app must not assume the directory is populated at install time;
  check for the provider's presence before reading shared files.

---

## Connecting

After both snaps are installed, connect the plug to the slot:

```bash
snap connect <consumer-snap>:<plug-name> <provider-snap>:<slot-name>

# Example:
snap connect iotdevice-nginx:certbot-etc iotdevice-certbot:certbot-etc
```

Verify the connection:
```bash
snap connections <consumer-snap>
```

The connection takes effect immediately. Restart the consumer service to pick up
the new bind mount:
```bash
snap restart <consumer-snap>
```

---

## Verifying File Sharing at Runtime

The content interface creates bind mounts inside the consumer's mount namespace,
not on the host filesystem. Inspect from within the namespace:

```bash
# Find the consumer service's mount namespace
lxc exec snap-test -- nsenter --mount=/run/snapd/ns/<consumer-snap>.mnt \
  findmnt | grep "$SNAP_COMMON"

# Read a file through the consumer's view
lxc exec snap-test -- nsenter --mount=/run/snapd/ns/<consumer-snap>.mnt \
  cat /var/snap/<consumer-snap>/common/shared/somefile
```

The host path `/var/snap/<consumer-snap>/common/shared` will appear empty
until the consumer's service is running (the mount is part of the service's
namespace setup).

---

## Double-Bind Warning

> **Do not declare a layout for the same path that a content plug's `target`
> resolves to.**

**What goes wrong:** The layout bind (`/etc/letsencrypt → $SNAP_COMMON/letsencrypt`)
is set up from an initial snapshot of `$SNAP_COMMON/letsencrypt` at namespace
setup time, before the content interface bind replaces `$SNAP_COMMON/letsencrypt`
with the provider's directory. The result is that `/etc/letsencrypt` inside the
consumer's namespace remains empty, pointing to the original (empty) directory,
even though `$SNAP_COMMON/letsencrypt` correctly shows the provider's files.

**Correct approach:** Reference `$SNAP_COMMON/<subpath>` directly in the
application's config. At build time, patch the application's config file to use
the `$SNAP_COMMON` path (`/var/snap/<snap-name>/common/<subpath>`) instead of the
classic path (`/etc/letsencrypt`). Use an `override-build` step placed **after**
`craftctl default` to apply the patch:

```yaml
override-build: |
  craftctl default
  CONF="$CRAFT_PART_INSTALL/etc/myapp/myapp.conf"
  # Redirect classic path to the $SNAP_COMMON path where the content
  # interface will mount the provider's shared directory
  sed -i 's|/etc/letsencrypt|/var/snap/myapp/common/letsencrypt|g' "$CONF"
```

---

## Minimal Working Example

**Provider (`iotdevice-certbot`):**
```yaml
slots:
  certbot-etc:
    interface: content
    content: certbot-etc
    write:
      - $SNAP_COMMON/letsencrypt
  certbot-var:
    interface: content
    content: certbot-var
    write:
      - $SNAP_COMMON/www/certbot
```

Install hook creates the directories:
```bash
mkdir -p "$SNAP_COMMON/letsencrypt"
mkdir -p "$SNAP_COMMON/www/certbot"
```

**Consumer (`iotdevice-nginx`):**
```yaml
plugs:
  certbot-etc:
    interface: content
    content: certbot-etc
    target: $SNAP_COMMON/letsencrypt
  certbot-var:
    interface: content
    content: certbot-var
    target: $SNAP_COMMON/www/certbot

apps:
  entrypoint:
    plugs:
      - certbot-etc
      - certbot-var
```

`nginx.conf` is patched at build time to reference the `$SNAP_COMMON` paths:
```yaml
override-build: |
  craftctl default
  NGINX_CONF="$CRAFT_PART_INSTALL/etc/nginx/nginx.conf"
  sed -i 's|/etc/letsencrypt|/var/snap/iotdevice-nginx/common/letsencrypt|g' \
    "$NGINX_CONF"
  sed -i 's|/var/www/certbot|/var/snap/iotdevice-nginx/common/www/certbot|g' \
    "$NGINX_CONF"
```

**Connect after install:**
```bash
snap connect iotdevice-nginx:certbot-etc iotdevice-certbot:certbot-etc
snap connect iotdevice-nginx:certbot-var iotdevice-certbot:certbot-var
snap restart iotdevice-nginx
```
