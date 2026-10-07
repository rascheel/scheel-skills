## 1. snap-analyzer

- [x] 1.1 `references/analysis-checklist.md` §4: add an app-type decision before the service items: find and record upstream's main usage; command app when each run takes user-chosen arguments; service only for a real signal; both apps (`<binary>` + `daemon`) when both apply; service-only only with a recorded reason. Reword "README describes it as a server" so it is not a service signal by itself
- [x] 1.2 `references/analysis-checklist.md` §4 and §7: snap options only when something reads them; `home`/`removable-media` only for apps that can reach user-chosen paths
- [x] 1.3 `SKILL.md` Step 1: summarise the app-type decision and point to the checklist
- [x] 1.4 `SKILL.md` Step 6 field rules: `apps[].daemon`, app naming, command passes arguments through, no invented `config_options`; add the app-type check to the pre-report self-check
- [x] 1.5 `SKILL.md` Step 7: report each app's type and the usage or signal behind it

## 2. snapcraft-author

- [x] 2.1 `SKILL.md` Step 2a: a wrapper for a command app ends in `exec "$SNAP/…" "$@"` and doesn't hardcode a path the user would choose; render every app the analysis lists
- [x] 2.2 Check `assets/` and `references/` for wrappers that drop arguments and fix any found

## 3. Specs, versions and verification

- [x] 3.1 Validate this change with `openspec validate --strict`, apply the deltas to `openspec/specs/` and archive it
- [x] 3.2 Bump skill versions: minor for snap-analyzer and snapcraft-author
- [x] 3.3 Run `python3 schema/validate_contracts.py --self-test` (no schema change expected)
- [ ] 3.4 Hand off to the harness: `darkhttpd` is a command app that passes arguments through, with no invented `port` option or `configure` hook, and passes 5/5; no regressions in `dufs` (7/7, command), `ollama` (5/5, command + service), `simple-server` (4/4, service), `htop` and `helix` (commands)
