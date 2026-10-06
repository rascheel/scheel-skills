# Snap Packaging Skills

A set of AI agent skills that automate the full lifecycle of packaging applications as snaps — from codebase analysis through building, validating, and publishing to the Snap Store. Compatible with Claude Code, Gemini CLI, and other skill-aware AI agents.

## Skills Overview

| Skill | Purpose |
|-------|---------|
| **snap-builder** | **Start here.** Entry point for the full pipeline: analyze → package → validate → patch → rebuild (looping until clean or max iterations) |
| **snap-analyzer** | Scans a codebase and produces `snap-analysis.json` — a structured packaging specification covering language, plugin, interfaces, hooks, and layouts |
| **snap-oci-analyzer** | Analyzes OCI/container input and produces the same specification with OCI-specific packaging facts |
| **snapcraft-author** | Pipeline stage: reads `snap-analysis.json` and generates `snap/snapcraft.yaml`, lifecycle hooks, and `SNAP_PACKAGING.md`, then builds the snap |
| **snap-validator** | Installs the snap in a clean LXD container, exercises all apps/daemons, captures AppArmor/SecComp denials, and writes `snap-validation-results.json` |
| **snap-trimmer** | Shrinks an already-built snap by editing `snapcraft.yaml` — finds unused libraries, base/content-snap duplicates, and over-copied build scratch, then rebuilds and verifies no regression |
| **snap-publisher** | Interactively guides uploading, releasing, and promoting snaps to the Snap Store |
| **mattermost** | Independent Mattermost REST API messaging skill; not part of the Snap packaging pipeline |

### Pipeline Architecture

`snap-builder` is the entry point: it detects the input type, runs one of the two
analyzers, then drives snapcraft-author and snap-validator in a build loop. Everything inside the
double-lined frame runs under its control:

```
      Source code project             OCI / container input
    (go.mod, Cargo.toml, …)        (image ref, Docker Hub URL,
                                      docker save .tar, or
                                     config.json + rootfs/)
               │                                │
╔══════════════╪════════ snap-builder ══════════╪═══════════════════╗
║              ▼                                ▼                   ║
║    ┌───────────────────┐            ┌───────────────────┐         ║
║    │   snap-analyzer   │            │ snap-oci-analyzer │         ║
║    └─────────┬─────────┘            └─────────┬─────────┘         ║
║              │                                │                   ║
║              └──────────────┬─────────────────┘                   ║
║                             │  runs exactly one analyzer          ║
║                             ▼                                     ║
║               /tmp/snap-analysis-<dir>.json                       ║
║          (same contract; `oci` block only for OCI input)          ║
║                             │                                     ║
║                             ▼                                     ║
║                   ┌──────────────────┐   ┌──────────────┐         ║
║                   │ snapcraft-author │──▶│snap-validator│         ║
║                   └──────────────────┘   └──────────────┘         ║
║                             ▲                   │                 ║
║                             │  patch & rebuild  │                 ║
║                             └───────────────────┘                 ║
║        denials → plugs/layouts · devmode crash → build fix        ║
║         OCI only: reproducibility diffs → override steps          ║
║                                                                   ║
║             loops until clean, or until a cap is hit:             ║
║   5 denial patches · 3 devmode fixes · 3 reproducibility fixes    ║
╚═════════════════════════════╤═════════════════════════════════════╝
                              │
                              ▼
                       validated .snap
                              │  standalone skills, run separately
                              ▼
                      ┌──────────────┐     ┌──────────────┐
                      │ snap-trimmer │────▶│snap-publisher│
                      └──────────────┘     └──────────────┘
                         (optional)         (Snap Store)
```

The skills communicate through files on disk:
- `/tmp/snap-analysis-<dir>.json` — `snap-analyzer` or `snap-oci-analyzer` → snapcraft-author (transient hand-off, kept out of the repo)
- `snap/snapcraft.yaml` — snapcraft-author → validator
- `snap-validation-results.json` — validator → snapcraft-author (patch mode)

**snap-trimmer** and **snap-publisher** are standalone skills — neither is part of the orchestrated pipeline. Both operate on an already-built `.snap`: run **snap-trimmer** after the pipeline produces a `.snap` to shrink it (it edits `snapcraft.yaml` and rebuilds, never touching the artifact directly), then **snap-publisher** when you're ready to upload to the Store.

## Installation

Install individual skills using the `skills` CLI. Each skill is self-contained and can be added independently:

```bash
# Install a single skill (e.g., snap-trimmer for Claude Code)
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-trimmer -a claude-code -g

# Install all Snap packaging skills
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-builder -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-analyzer -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-oci-analyzer -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snapcraft-author -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-validator -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-trimmer -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-publisher -a claude-code -g
```

`mattermost` is independent of the Snap workflow and can be installed separately when
needed:

```bash
npx skills add https://github.com/rascheel/scheel-skills/tree/main/mattermost -a claude-code -g
```

Replace `-a claude-code` with your agent of choice (e.g., `-a gemini-cli`). The `-g` flag installs globally (user-level); omit it to install into the current project only.

## Usage

### Full pipeline (recommended)

Ask your AI agent to package your project as a snap — snap-builder will coordinate all phases automatically:

> "Package this project as a snap"

### Individual skills

You can also invoke skills individually:

- **Analyze only:** "Analyze this project for snap packaging" → produces `/tmp/snap-analysis-<project-dir>.json`
- **Analyze OCI/container input:** "Analyze this image for snap packaging" → `snap-oci-analyzer` produces `/tmp/snap-analysis-<project-dir>.json` with OCI facts
- **Package only:** "Generate snapcraft.yaml from snap-analysis.json" → produces snap files and builds
- **Validate only:** "Validate the snap in this directory" → tests in LXD and reports denials
- **Trim:** "My snap is too big — shrink it" → edits `snapcraft.yaml`, rebuilds, and verifies no regression
- **Publish:** "Publish this snap to the Snap Store" → interactive upload and release workflow
