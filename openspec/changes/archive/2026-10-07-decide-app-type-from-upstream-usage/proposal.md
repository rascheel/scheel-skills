## Why

The analyzer packaged darkhttpd, a server that upstream runs as `darkhttpd <wwwroot> --port N`,
as a service only (`daemon: simple`). snapd puts no `/snap/bin` command on the path for a
service, so users could not run it on a directory of their choice. The wrapper hardcoded
`$SNAP_COMMON/www`, the `home` and `removable-media` plugs could never take effect, and the
analysis invented a `port` snap option plus `configure` and `install` hooks that upstream
has no equivalent of. dufs, an equivalent app, was packaged correctly as a command on a
different run. Nothing in the analyzer decides app type, so the result depends on the run.

The analyzer's checklist only lists signals that push towards a service ("README describes
it as a server", "start on boot"). It never asks how upstream expects the app to be run.

## What Changes

- **snap-analyzer decides app type from upstream's main usage.** It finds that usage in the
  README, `--help` text, man pages and bundled unit files, and records it in `notes[]`.
  - When each run takes arguments the user chooses (a path to serve, input files, flags)
    and runs in the foreground, it ships a command app (`daemon: null`) whose command
    passes arguments through.
  - It adds a service app only for a real signal: a bundled systemd unit or init script, a
    documented service mode (such as `ollama serve`), a fixed config file read at startup,
    or upstream docs saying it should start on boot.
  - When both apply it ships both: the command app named after the binary, plus a service
    app named `daemon`.
  - A service-only snap is allowed only when upstream is purely a service, with the reason
    recorded.
- **Plugs and snap options match the app type.** `home` and `removable-media` are declared
  only for apps whose command can reach user-chosen paths. Snap options are recorded only
  when the app or a justified service wrapper reads them, never to give a plain command a
  fixed configuration.
- **snapcraft-author renders command wrappers that pass arguments through**
  (`exec … "$@"`), and doesn't hardcode a path that the user would normally choose.

No schema change: `apps[].daemon` already expresses the decision.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `snap-analyzer`: new requirements for choosing app type from upstream usage and for
  keeping plugs and snap options consistent with it.
- `snapcraft-author`: command-app wrappers pass arguments through.

## Impact

- **Skills:** `snap-analyzer` (`SKILL.md`, `references/analysis-checklist.md`),
  `snapcraft-author` (`SKILL.md`).
- **Schemas:** none.
- **Not affected:** `snap-oci-analyzer` (it classifies service versus command for
  `docker-to-snap` separately; out of scope), `snap-validator`, `snap-builder`,
  `snap-trimmer`, `snap-publisher`, `mattermost`.
