## Why

A source-built daemon that reads its settings with `snapctl get` was packaged with only an
`install` hook, and the pipeline reported it clean. snapd rejects every `snap set` on a
snap without a `configure` hook ("snap has no 'configure' hook"), so the snap could not
be configured at all. Each stage had a gap that let this through:

- `snap-analyzer` treats `configure` as optional ("respond to `snap set` changes") and has
  no structured place to record snap options for a source build.
- `snapcraft-author` only knows how to render a `configure` hook from `oci.config_options[]`.
- `snap-validator` never runs `snap set`, so the snap validated as `clean: true` and the
  final report claimed it was "configurable via snap options" without testing it.

## What Changes

- **Analysis schema 1.3** adds an optional top-level `config_options[]` for source builds,
  with a `snapctl` source (the app reads the option itself), a `boolean` type and a
  `restart_required` flag.
  `oci.config_options[]` is unchanged.
- **New contract invariant:** an analysis that lists any snap option (top-level or under
  `oci`) MUST list `configure` in `hooks[]`. `schema/validate_contracts.py` enforces it,
  with or without the `jsonschema` library.
- **snap-analyzer** detects `snapctl get` usage and records each option's key, type,
  default, and whether a running daemon must restart to pick up a change. It lists
  `configure` whenever it records an option.
- **snapcraft-author** renders a source-mode `configure` hook from `config_options[]`:
  validate non-empty values by type, restart affected daemons only when they are running,
  and write no config file when the app reads `snapctl get` itself. `SNAP_PACKAGING.md`
  documents the `snap set` keys in source mode too.
- **Validation results schema 1.2** adds an optional `config_check` object.
  **snap-validator** runs `snap set` when the snap has snap options: it re-applies an
  option's current value (any type), or sets another allowed value for an `enum` option.
  It checks that `snap set` succeeds and that daemons stay up, and records the outcome.
  A failed `snap set` becomes a `config-set-failed` diagnostic.
- **`diagnostics[]` is redefined** from "pre-flight failures" to "non-denial failures", so
  it can carry `config-set-failed`. snap-builder's routing is unchanged: any diagnostic
  stops the pipeline.
- **snap-builder's final report** lists the `snap set` keys and only calls the snap
  configurable when the validator's config check passed.
- **BREAKING (wording only):** both analyzers always write the current analysis schema
  version (`"1.3"`). The rule that `schema_version` is `"1.0"` unless `target_arch` is set
  is removed. Consumers already accept every version, so no reader changes.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `pipeline-contracts`: new snap-options/`configure` invariant enforced by the gate;
  `diagnostics[]` covers non-denial failures; schema versions 1.3 (analysis) and 1.2
  (results); producers write the current version.
- `snap-analyzer`: records source-mode snap options and lists `configure` for them;
  drops the conditional `schema_version` rule.
- `snapcraft-author`: renders source-mode `configure` hook bodies and documents `snap set`
  keys for source builds.
- `snap-validator`: exercises `snap set` and reports the result in `config_check` or as a
  `config-set-failed` diagnostic.
- `snap-builder`: final report covers snap options and their tested status.
- `snap-oci-analyzer`: writes the current schema version (`1.3`) and keeps options only in
  `oci.config_options[]`.

## Impact

- **Schemas:** `schema/snap-analysis.schema.json` (1.3), `schema/snap-validation-results.schema.json`
  (1.2), `schema/examples/`, `schema/README.md`, and `schema/validate_contracts.py`
  (fallback checker gains `allOf`, `const`, `contains`, `minItems`).
- **Skills:** `snap-analyzer` (SKILL.md, `references/analysis-checklist.md`,
  `references/snap-hooks-reference.md`), `snapcraft-author` (SKILL.md,
  `references/snap-hooks-reference.md`, `assets/configure-hook-template.sh`),
  `snap-validator` (SKILL.md), `snap-builder` (SKILL.md). `snap-oci-analyzer` changes only
  the `schema_version` it writes.
- **OCI path:** `oci.config_options[]` rendering is untouched. Existing OCI analyses already
  list `configure` when they have options, so the new invariant does not reject them; the
  harness `redis` and `postgresql` fixtures should be re-run to confirm.
- **Not affected:** `snap-trimmer`, `snap-publisher`, `mattermost`.
