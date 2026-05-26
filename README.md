# Snap Packaging Skills

A set of AI agent skills that automate the full lifecycle of packaging applications as snaps — from codebase analysis through building, validating, and publishing to the Snap Store. Compatible with Claude Code, Gemini CLI, and other skill-aware AI agents.

## Skills Overview

| Skill | Purpose |
|-------|---------|
| **snap-analyzer** | Scans a codebase and produces `snap-analysis.json` — a structured packaging specification covering language, plugin, interfaces, hooks, and layouts |
| **snap-packager** | Reads `snap-analysis.json` and generates `snap/snapcraft.yaml`, lifecycle hooks, and `SNAP_PACKAGING.md`, then builds the snap |
| **snap-validator** | Installs the snap in a clean LXD container, exercises all apps/daemons, captures AppArmor/SecComp denials, and writes `snap-validation-results.json` |
| **snap-orchestrator** | Coordinates the full pipeline: analyze → package → validate → patch → rebuild (looping until clean or max iterations) |
| **snap-publisher** | Interactively guides uploading, releasing, and promoting snaps to the Snap Store |

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
- `snap-analysis.json` — analyzer → packager
- `snap/snapcraft.yaml` — packager → validator
- `snap-validation-results.json` — validator → packager (patch mode)

**snap-publisher** is a separate, standalone skill — it is not part of the orchestrated pipeline. Use it after the pipeline produces a `.snap` file and you're ready to upload to the Store.

## Installation

Install individual skills using the `skills` CLI. Each skill is self-contained and can be added independently:

```bash
# Install a single skill (e.g., snap-packager for Claude Code)
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-packager -a claude-code -g

# Install all five skills
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-analyzer -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-packager -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-validator -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-orchestrator -a claude-code -g
npx skills add https://github.com/rascheel/scheel-skills/tree/main/snap-publisher -a claude-code -g
```

Replace `-a claude-code` with your agent of choice (e.g., `-a gemini-cli`). The `-g` flag installs globally (user-level); omit it to install into the current project only.

## Usage

### Full pipeline (recommended)

Ask your AI agent to package your project as a snap — the orchestrator will coordinate all phases automatically:

> "Package this project as a snap"

### Individual skills

You can also invoke skills individually:

- **Analyze only:** "Analyze this project for snap packaging" → produces `snap-analysis.json`
- **Package only:** "Generate snapcraft.yaml from snap-analysis.json" → produces snap files and builds
- **Validate only:** "Validate the snap in this directory" → tests in LXD and reports denials
- **Publish:** "Publish this snap to the Snap Store" → interactive upload and release workflow
