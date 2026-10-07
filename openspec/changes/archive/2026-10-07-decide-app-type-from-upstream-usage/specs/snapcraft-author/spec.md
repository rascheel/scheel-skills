## ADDED Requirements

### Requirement: Command wrappers pass arguments through
When the skill renders a wrapper script for a command app (`daemon: null`), the wrapper SHALL end by exec'ing the binary with `"$@"`, and MUST NOT hardcode a path or flag that the user would choose on each run. The skill SHALL render every app the analysis lists, with the app type the analysis records.

#### Scenario: Wrapped command app
- **WHEN** the analysis lists a command app whose command is a wrapper script
- **THEN** the generated wrapper's last command is `exec "$SNAP/<path-to-binary>" "$@"` and running `<snap> <dir>` passes `<dir>` to the binary

#### Scenario: Command and service apps
- **WHEN** the analysis lists a command app and a service app named `daemon`
- **THEN** `snapcraft.yaml` has both apps, and only `daemon` has a `daemon:` key
