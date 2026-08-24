# Content-Interface Discovery

Use this reference only when two or more separately installed snaps need to share a
writable directory. A single snap that needs to redirect one of its own hardcoded paths
uses a `layout:` instead.

## Identify the Shared Data

Inspect Docker Compose volumes, OCI mounts, upstream deployment documentation, and the
application configuration. Record a content-interface fact only when all of these are
true:

- Two different snaps use the same runtime data.
- One snap owns or writes the directory.
- The other snap needs to read or write it after installation.

Do not use a content interface for image files, build-time artifacts, or a directory used
only inside one snap.

## Record Provider and Consumer Facts

For each shared directory, determine:

| Question | Fact to record |
|---|---|
| Which snap creates and owns the data? | `role: "provider"` |
| Which snap consumes the data? | `role: "consumer"` |
| What identifies the shared data? | Shared `content_label` |
| Where is it mounted? | `path: "$SNAP_COMMON/<subpath>"` |
| Which peer is expected? | `snap_name_hint` |

Record one fact per role. Provider and consumer entries must use the same
`content_label`; their `slot_or_plug_name` values identify the corresponding endpoint.

```json
[
  {
    "role": "provider",
    "slot_or_plug_name": "certificates",
    "content_label": "certificates",
    "path": "$SNAP_COMMON/certificates",
    "snap_name_hint": "cert-manager"
  },
  {
    "role": "consumer",
    "slot_or_plug_name": "certificates",
    "content_label": "certificates",
    "path": "$SNAP_COMMON/certificates",
    "snap_name_hint": "web-server"
  }
]
```

## Constraints to Record in Notes

- The provider must create its `$SNAP_COMMON` directory during installation.
- The consumer target is empty until an operator runs `snap connect`.
- Do not add a `layout:` whose target resolves to the same path as a consumer content
  plug. This double bind leaves the application with an empty directory.
- Do not set `default-provider` for locally built snaps; document the manual connection
  instead.

`snap-packager` renders these facts. Read its
`references/content-interface-guide.md` for the exact slot/plug YAML and runtime
connection commands; do not write `snapcraft.yaml` from this skill.
