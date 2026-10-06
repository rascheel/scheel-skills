# Pipeline contract schemas

The living definition of the two JSON files the `snap-builder` sub-agents exchange:

- `snap-analysis.schema.json` — written by `snap-analyzer` (source) or `snap-oci-analyzer`
  (OCI), read by `snapcraft-author`. Schema **1.1** = schema 1.0 **plus** the optional
  top-level `oci` block (present only for container input). Schema **1.2** = schema 1.1
  **plus** the optional top-level `target_arch` field, for cross-architecture *source*
  builds — mutually exclusive with `oci.target_arch` (the schema rejects an analysis that
  sets both), which remains the authoritative source for OCI-derived snaps (a container
  image is single-arch by construction). Schema **1.3** = schema 1.2 **plus** the optional
  top-level `config_options` array, for snap options in *source* builds (`source: "snapctl"`
  when the app reads the option itself with `snapctl get`, a `boolean` type, and
  `restart_required`). OCI analyses keep recording options only in `oci.config_options`.
- `snap-validation-results.schema.json` — written by `snap-validator`, read by
  `snapcraft-author` (patch mode) and `snap-builder`. Schema **1.1** = schema 1.0 **plus**
  the optional fields `diagnostics`, `oci_mode`, `devmode_pass`, `devmode_notes`,
  `target_arch`, `test_environment_used`, `store_review_interfaces`, `reproducibility`.
  `devmode_pass`/`devmode_notes` and `store_review_interfaces` are populated for every run
  (OCI or source-built); `target_arch`/`test_environment_used` are populated whenever a
  non-host architecture is targeted (from either `oci.target_arch` or the new top-level
  `target_arch`); `oci_mode` and `reproducibility` stay OCI-only. Schema **1.2** = schema 1.1
  **plus** the optional `config_check` object, the outcome of the validator's `snap set`
  check (`null` when the snap has no snap options and no `configure` hook). `diagnostics`
  carries every failure that is not a confinement denial, whether found before the snap
  runs (for example, `missing-snap`) or while exercising it (for example,
  `config-set-failed`); any diagnostic makes `clean` false.

Every bump is **additive**: an older producer/consumer still interoperates. Producers always
write the current version (`1.3` for the analysis, `1.2` for results), whichever optional
fields they populate; consumers accept every version.

## Snap options require a `configure` hook

snapd rejects every `snap set` on a snap that has no `configure` hook. The analysis schema
therefore requires `hooks` to contain `configure` whenever top-level `config_options` or
`oci.config_options` is non-empty, and the contract gate rejects an analysis that breaks
this rule.

## Contract gate (LXD-free)

```bash
# Validate the bundled examples, and confirm the invalid ones are rejected:
python3 validate_contracts.py --self-test

# Same, forcing the built-in checker even when jsonschema is installed:
python3 validate_contracts.py --self-test --fallback

# Validate real pipeline artifacts:
python3 validate_contracts.py \
  --analysis /tmp/snap-analysis-$(basename "$PWD").json \
  --results  snap-validation-results.json
```

Exit codes: `0` all valid · `1` a validation error · `2` usage/file error. The script uses
the `jsonschema` library when installed and otherwise falls back to a built-in structural
checker, so it runs in CI/pre-commit with no extra dependencies — and without needing
`snapcraft` or LXD. Run it as a fast gate before the two full end-to-end pipeline runs.

`examples/` holds valid instances — used by `--self-test` and handy as copy-paste
templates:

- `snap-analysis.source.json`, `snap-analysis.source-options.json` (a daemon with snap
  options), `snap-analysis.oci.json`
- `snap-validation-results.source.json`, `snap-validation-results.oci.json`,
  `snap-validation-results.failure.json` (pre-flight diagnostic),
  `snap-validation-results.config-failure.json` (`config-set-failed` diagnostic)

`examples/invalid/` holds instances that `--self-test` expects the gate to reject (snap
options without a `configure` hook).
