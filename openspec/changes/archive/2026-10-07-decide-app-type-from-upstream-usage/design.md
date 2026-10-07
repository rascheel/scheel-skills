## Context

App type (command, service, or both) is the analyzer's call; snapcraft-author renders it
without second-guessing. Today the analyzer has no rule for it. The darkhttpd run chose a
service because the README calls it a "web server", then invented configuration to run
that service (a fixed root, a `port` snap option, hooks). Because the configure-hook rule
(`f623426`) now makes any snap option require a `configure` hook, an invented option also
drags in hooks, so the cost of a wrong call is larger.

## Goals / Non-Goals

**Goals:** a deterministic, evidence-based app-type decision; plugs and snap options that
match it; command wrappers that pass arguments through.

**Non-Goals:** the OCI path (`snap-oci-analyzer` Phase 0c); schema changes; changing how
the validator or harness exercise apps.

## Decisions

### 1. Decide from upstream's main usage, not from how the README describes the app

The question is "how does upstream expect this to be run?", answered from usage examples,
`--help`/usage text, man pages and bundled unit files. Calling the app a "server" is not a
service signal by itself: darkhttpd and dufs are servers that users run on a directory.

### 2. Command only by default; a service needs a real signal

A real signal is a bundled systemd unit or init script, a documented service mode, a fixed
config file the app reads at startup, or upstream docs saying it should start on boot.

*Alternative: also ship a disabled service (`install-mode: disable`) for every server
command.* Rejected: such a service needs a fixed root, a snap option and hooks that
upstream doesn't have. The analysis schema also has no field for `install-mode`.

### 3. Both apps when both apply; the service is named `daemon`

The command app is named after the binary so users run `<snap>` (or `<snap>.<binary>`);
the service app is named `daemon` (so `snap.<snap>.daemon`). This matches what the passing
ollama run produced. *Alternatives `<binary>d` and `server`* were rejected: `<binary>d`
is odd unless upstream already ships one, and `server` doesn't fit non-network services.
When upstream already ships a separate service binary (for example `foo` and `food`),
naming the apps after the binaries takes precedence.

### 4. Plugs and options follow the app type

`home` and `removable-media` only help an app that serves or opens user-chosen paths, so
they are declared only for such an app (typically the command app). A root service's
`home` reaches only `/root`. Snap options are recorded only when something reads them: the
upstream code, or the wrapper of a service app that Decision 2 justified.

## Risks / Trade-offs

- **Judgement remains.** "A fixed config file the app reads at startup" can be argued for
  many apps. The analyzer must record which signal it used in `notes[]`, so a reviewer
  can see and challenge it.
- **A server shipped as a command doesn't start on boot.** That matches upstream; users who
  want a service can run it from their own unit, and the analysis notes explain the choice.
