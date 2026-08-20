# Pipeline contract schemas

The living definition of the two JSON files the `snap-orchestrator` sub-agents exchange:

- `snap-analysis.schema.json` — written by `snap-analyzer` (source) or `snap-oci-analyzer`
  (OCI), read by `snap-packager`. Schema **1.1** = schema 1.0 **plus** the optional
  top-level `oci` block (present only for container input). Schema **1.2** = schema 1.1
  **plus** the optional top-level `target_arch` field, for cross-architecture *source*
  builds — mutually exclusive with `oci.target_arch`, which remains the authoritative
  source for OCI-derived snaps (a container image is single-arch by construction).
- `snap-validation-results.schema.json` — written by `snap-validator`, read by
  `snap-packager` (patch mode) and `snap-orchestrator`. Schema **1.1** = schema 1.0 **plus**
  the optional fields `diagnostics`, `oci_mode`, `devmode_pass`, `devmode_notes`,
  `target_arch`, `test_environment_used`, `store_review_interfaces`, `reproducibility`.
  `devmode_pass`/`devmode_notes` and `store_review_interfaces` are populated for every run
  (OCI or source-built); `target_arch`/`test_environment_used` are populated whenever a
  non-host architecture is targeted (from either `oci.target_arch` or the new top-level
  `target_arch`); `oci_mode` and `reproducibility` stay OCI-only. `diagnostics` carries
  validation pre-flight failures (for example, a missing `.snap`) rather than denials.

All three bumps are **additive**: a schema-1.0/1.1 producer/consumer still interoperates.

## Contract gate (LXD-free)

```bash
# Validate the bundled OCI + source examples:
python3 validate_contracts.py --self-test

# Validate real pipeline artifacts:
python3 validate_contracts.py \
  --analysis /tmp/snap-analysis-$(basename "$PWD").json \
  --results  snap-validation-results.json
```

Exit codes: `0` all valid · `1` a validation error · `2` usage/file error. The script uses
the `jsonschema` library when installed and otherwise falls back to a built-in structural
checker, so it runs in CI/pre-commit with no extra dependencies — and without needing
`snapcraft` or LXD. Run it as a fast gate before the two full end-to-end pipeline runs.

`examples/` holds valid source, OCI, and diagnostics-only validation instances, one per
file mode (`*.oci.json`, `*.source.json`, `*.failure.json`) — used by `--self-test` and
handy as copy-paste templates.
