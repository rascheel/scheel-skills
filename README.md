# Snap Packaging Skills

A set of AI agent skills that automate the full lifecycle of packaging applications as snaps — from codebase analysis through building, validating, and publishing to the Snap Store. Compatible with Claude Code, Gemini CLI, and other skill-aware AI agents.

## Skills Overview

| Skill | Purpose |
|-------|---------|
| **snap-analyzer** | Scans a codebase and produces `snap-analysis.json` — a structured packaging specification covering language, plugin, interfaces, hooks, and layouts |
| **snap-oci-analyzer** | Analyzes OCI/container input and produces the same specification with OCI-specific packaging facts |
| **snap-packager** | Reads `snap-analysis.json` and generates `snap/snapcraft.yaml`, lifecycle hooks, and `SNAP_PACKAGING.md`, then builds the snap |
| **snap-validator** | Installs the snap in a clean LXD container, exercises all apps/daemons, captures AppArmor/SecComp denials, and writes `snap-validation-results.json` |
| **snap-orchestrator** | Coordinates the full pipeline: analyze → package → validate → patch → rebuild (looping until clean or max iterations) |
| **snap-trimmer** | Shrinks an already-built snap by editing `snapcraft.yaml` — finds unused libraries, base/content-snap duplicates, and over-copied build scratch, then rebuilds and verifies no regression |
| **snap-publisher** | Interactively guides uploading, releasing, and promoting snaps to the Snap Store |
| **mattermost** | Independent Mattermost REST API messaging skill; not part of the Snap packaging pipeline |

### Pipeline Architecture

The orchestrator coordinates three skills in a build loop:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ snap-analyzer│────▶│ snap-packager│────▶│snap-validator│
└──────────────┘     └──────────────┘     └──────────────┘
                             ▲                     │
                             │   patch & rebuild   │
                             └─────────────────────┘

         snap-orchestrator manages this flow
```

The skills communicate through files on disk:
- `/tmp/snap-analysis-<dir>.json` — analyzer → packager (transient hand-off, kept out of the repo)
- `snap/snapcraft.yaml` — packager → validator
- `snap-validation-results.json` — validator → packager (patch mode)

**snap-trimmer** and **snap-publisher** are standalone skills — neither is part of the orchestrated pipeline. Both operate on an already-built `.snap`: run **snap-trimmer** after the pipeline produces a `.snap` to shrink it (it edits `snapcraft.yaml` and rebuilds, never touching the artifact directly), then **snap-publisher** when you're ready to upload to the Store.

## Installation

Install individual skills using the `skills` CLI. Each skill is self-contained and can be added independently:

```bash
# Install a single skill (e.g., snap-packager for Claude Code)
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-packager -a claude-code -g

# Install all Snap packaging skills
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-analyzer -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-oci-analyzer -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-packager -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-validator -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-orchestrator -a claude-code -g
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

Ask your AI agent to package your project as a snap — the orchestrator will coordinate all phases automatically:

> "Package this project as a snap"

### Individual skills

You can also invoke skills individually:

- **Analyze only:** "Analyze this project for snap packaging" → produces `/tmp/snap-analysis-<project-dir>.json`
- **Analyze OCI/container input:** "Analyze this image for snap packaging" → `snap-oci-analyzer` produces `/tmp/snap-analysis-<project-dir>.json` with OCI facts
- **Package only:** "Generate snapcraft.yaml from snap-analysis.json" → produces snap files and builds
- **Validate only:** "Validate the snap in this directory" → tests in LXD and reports denials
- **Trim:** "My snap is too big — shrink it" → edits `snapcraft.yaml`, rebuilds, and verifies no regression
- **Publish:** "Publish this snap to the Snap Store" → interactive upload and release workflow
