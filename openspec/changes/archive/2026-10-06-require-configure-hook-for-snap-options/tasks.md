## 1. Schemas and contract gate

- [x] 1.1 `schema/snap-analysis.schema.json`: add `"1.3"` to `schema_version`; add optional top-level `config_options[]` with its own item definition (the OCI item fields plus `restart_required`, `snapctl` in `source`, and `boolean` in `type`); leave `oci.config_options[]` unchanged (the fallback checker has no `$ref`, so the item shape is duplicated rather than shared); move the existing OCI/`target_arch` `if`/`then` into a top-level `allOf` alongside the two "options ⇒ `configure` in `hooks`" rules; update the description
- [x] 1.2 `schema/snap-validation-results.schema.json`: add `"1.2"` to `schema_version`; add optional `config_check` (`checked`, `key`, `value`, `value_changed`, `set_ok`, `daemons_active`, `notes`; nullable); reword the `diagnostics` description to "non-denial failures"; update the description
- [x] 1.3 `schema/validate_contracts.py`: extend the fallback checker with `allOf`, `const`, `contains` and `minItems`
- [x] 1.4 `schema/examples/`: bump `snap-analysis.source.json` and `snap-analysis.oci.json` to `1.3`; add `snap-analysis.source-options.json`, a daemon with top-level `config_options[]` and `install`/`configure` hooks (the existing source example is a CLI with no options); bump the results examples to `1.2` with `config_check` (`null` where there are no options); add a results example with a `config-set-failed` diagnostic
- [x] 1.5 Add negative fixtures under `schema/examples/invalid/`: a source analysis and an OCI analysis that have options but no `configure` hook, both expected to fail (update `validate_contracts.py --self-test` to assert expected failures, and add `--fallback` to force the built-in checker)
- [x] 1.6 `schema/README.md`: document analysis 1.3, results 1.2, the options ⇒ `configure` rule, and "producers write the current version"
- [x] 1.7 Run `python3 schema/validate_contracts.py --self-test`, with and without `jsonschema` installed

## 2. snap-analyzer (producer side of the analysis hand-off)

- [x] 2.1 `SKILL.md` Step 5: make `configure` mandatory whenever an option is recorded, stating snapd's "has no 'configure' hook" rejection as the reason; add `install` when any option has a non-null default
- [x] 2.2 `SKILL.md` Step 6: document top-level `config_options[]` in the output example and set `schema_version` to `"1.3"` unconditionally (drop the `1.0`/`1.2` rule)
- [x] 2.3 `SKILL.md` chat report: list snap options with defaults
- [x] 2.4 `references/analysis-checklist.md` §4: add the item "does the app (or a sourced helper) call `snapctl get`, or does the plan seed options with `snapctl set`? Record key, type (record `true`/`false` flags as `boolean`), default and whether a running daemon must restart"
- [x] 2.5 `references/snap-hooks-reference.md`: in the shared section, state that `configure` is required for any `snap set` to succeed, and add the "app reads `snapctl get` itself" pattern (validate, guarded restart, no config file)

## 3. snap-oci-analyzer (version only)

- [x] 3.1 `SKILL.md` and `references/analysis-output-contract.md`: write `schema_version: "1.3"`; state that options go only in `oci.config_options[]`

## 4. snapcraft-author (consumer of the analysis, consumer of results)

- [x] 4.1 `SKILL.md`: add source-mode rendering of the `configure` hook from top-level `config_options[]` (validate non-empty values by type, including `true`/`false` for `boolean`; restart daemons for `restart_required` options only when `snapctl services` reports them active; no config file for `source: "snapctl"`), and install-hook seeding of non-null defaults when unset
- [x] 4.2 `SKILL.md`: make `SNAP_PACKAGING.md` document `snap set` keys for source builds as well as OCI
- [x] 4.3 `references/snap-hooks-reference.md`: apply the same shared-section changes as 2.5, keeping the shared section byte-identical to the analyzer's copy (the author's copy only adds the OCI section)
- [x] 4.4 `assets/configure-hook-template.sh`: add a "app reads `snapctl get` directly" variant (validation + guarded restart, no config-file section), keeping the existing OCI variant intact
- [x] 4.5 `SKILL.md` patch mode: note that `config-set-failed` arrives as a diagnostic and stops the skill like any other diagnostic

## 5. snap-validator (producer of results)

- [x] 5.1 `SKILL.md`: add the snap option check after the strict-mode scan: if an `enum` option has another allowed value, set it, check daemons, and restore the original (`value_changed: true`); otherwise re-apply one option's current value from `snap get` (or `snap unset` it when unset; verified in LXD that `snap unset` runs the `configure` hook); check exit status and that daemons stay active, record denials seen during the check, write `config_check`, and add `config-set-failed` with snapd's error on failure; record `checked: false` when a `configure` hook exists but no option is recorded
- [x] 5.2 `SKILL.md`: set `clean` false when `diagnostics[]` is non-empty; write results `schema_version: "1.2"`; add the option check result to the summary

## 6. snap-builder (consumer of results)

- [x] 6.1 `SKILL.md` Step 3.3: note that `config-set-failed` is a diagnostic and stops the pipeline without patching
- [x] 6.2 `SKILL.md` Phase 4 report: list each snap option with a `snap set` example and the option check status; only call the snap configurable when `config_check` passed
- [x] 6.3 `SKILL.md` file-contracts table: mention `config_options` and `config_check`

## 7. Specs, versions and verification

- [x] 7.1 Apply the spec deltas in this change to `openspec/specs/` and archive the change
- [x] 7.2 Bump skill versions: minor for snap-analyzer, snapcraft-author, snap-validator, snap-builder; patch for snap-oci-analyzer
- [x] 7.3 Confirm every `SKILL.md` on both sides of the changed hand-offs is updated (analyzers → snapcraft-author; snap-validator → snapcraft-author and snap-builder)
- [ ] 7.4 Hand off to the harness for the acceptance runs: `simple-server` (analysis lists `configure`; hook validates and restarts; `SNAP_PACKAGING.md` lists keys; `run-snap-tests.sh` passes), deleting the hook yields `config-set-failed`, and no regressions in `darkhttpd`, `dufs`, `helix`, `htop`, `ollama`, `redis`, `postgresql`
