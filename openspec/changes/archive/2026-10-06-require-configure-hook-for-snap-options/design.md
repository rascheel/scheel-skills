## Context

The pipeline packaged `simple-server`, a shell daemon that reads `daemon.port`,
`daemon.host` and `daemon.msg` with `snapctl get`. The analysis noted the `snapctl get`
calls and planned to seed defaults in the `install` hook, but listed only `install` in
`hooks[]`. snapcraft-author correctly did not second-guess that, and snap-validator never
ran `snap set`, so nothing caught that snapd refuses `snap set` on a snap with no
`configure` hook.

Today snap options exist in the analysis only as `oci.config_options[]`, whose `source`
enum (`env_var | config_file | cli_flag`) assumes the hook translates options into
something the app reads. A source-built app that calls `snapctl get` itself has nowhere to
record its options.

## Goals / Non-Goals

**Goals:**
- Any snap whose analysis records a snap option ships a `configure` hook.
- The rule is enforced mechanically at the analysis hand-off, not only by prose.
- The validator proves `snap set` works before the pipeline calls a snap configurable.
- No change in behavior for existing OCI analyses.

**Non-Goals:**
- Merging `oci.config_options[]` and the new top-level `config_options[]` into one field.
- Making a failed `snap set` a patchable case in the build loop.
- Testing the semantic effect of every option type (that stays with the harness tests).

## Decisions

### 1. Record source-mode options in a new top-level `config_options[]`

Add an optional top-level `config_options[]` (analysis schema 1.3). Items reuse the OCI
item shape (`key`, `source`, `type`, `allowed_values`, `default`) plus `restart_required`
(boolean). The `source` enum gains `snapctl`, and the `type` enum gains `boolean`, which is
common for source-built apps (for example `debug=true`) and would otherwise be recorded as
a `string` the hook can't validate. Fields that only make sense for OCI wiring
(`config_file_*`, `wiring`) stay optional and unused for `snapctl`. The OCI item's enums
are unchanged.

*Alternative: list `configure` in `hooks[]` and describe keys in `notes[]`.* Rejected:
snapcraft-author would have to read keys out of free text, and the validator would have
no key or type to test with.

*Alternative: move `oci.config_options[]` to the top level for both producers.* Rejected
for now: it changes the OCI hand-off that `redis`/`postgresql` depend on, for no gain in
this fix. The two fields are independent: snap-oci-analyzer keeps writing only
`oci.config_options[]`, and snap-analyzer writes only the top-level field.

### 2. Enforce "options ⇒ `configure`" in the schema, and teach the fallback checker

Express the invariant in `snap-analysis.schema.json` as two `if`/`then` rules under a
top-level `allOf` (top-level `config_options` non-empty ⇒ `hooks` contains `configure`;
same for `oci.config_options`). The existing OCI/`target_arch` `if`/`then` moves into the
same `allOf`. Extend `validate_contracts.py`'s fallback checker with `allOf`, `const`,
`contains` and `minItems` so the rule holds without `jsonschema`.

*Alternative: a hand-written semantic check in `validate_contracts.py`.* Rejected: it
splits the contract between the schema and the script, and anyone validating with a stock
JSON Schema library would miss it.

### 3. Report the `snap set` outcome in a new `config_check` results field

Add an optional `config_check` object (results schema 1.2), shaped like `reproducibility`:
`checked`, `key`, `value`, `value_changed`, `set_ok`, `daemons_active`, `notes`. It is
`null` when the snap has no snap options and no `configure` hook. `value_changed` records
whether the check set a different value (exercising validation and restart) or only
re-applied the current one (proving the hook exists and accepts a valid value). A failing `snap set` also produces a `config-set-failed`
diagnostic, so `clean` is false and snap-builder stops.

This lets snap-builder tell "tested and passed" apart from "not tested" (for example, when
the snap declares a `configure` hook but the analysis records no option to set) instead of
inferring success from the absence of a diagnostic.

*Alternative: diagnostics only, no new field.* Rejected: absence of a diagnostic can't
distinguish "passed" from "skipped", which is the exact gap that let the final report
claim untested configurability.

### 4. Widen `diagnostics[]` instead of adding a new failure field

`diagnostics[]` is defined as pre-flight failures, and a failed `snap set` is not one.
Rewording it to "non-denial failures" keeps a single stop signal for snap-builder and needs
no change to its routing. `code` is already a free-form string.

### 5. Stop the pipeline on `config-set-failed`; don't patch

snapcraft-author must take hook decisions from the analysis, so it can't add a missing
`configure` hook without a rule change. With decision 2 in place, a missing hook is
rejected at the hand-off; reaching `config-set-failed` means something regressed, and
stopping with snapd's error is the clearest outcome.

### 6. Guard the restart in the generated hook

snapd runs `configure` during installation, before services start. The generated hook
restarts a daemon only when `snapctl services <snap>.<app>` reports it active, so the
install-time run never depends on how `snapctl restart` treats a service that hasn't
started. Daemons are restarted only for options with `restart_required: true`.

### 7. Producers always write the current analysis schema version

Replace "`1.0` unless `target_arch` is set, then `1.2`" with "write `1.3`". Version rules
keyed to which optional fields are present are hard for an agent to follow (the bundled
source example already violates the current rule) and multiply with each additive bump.
Every consumer already accepts all versions. This touches snap-oci-analyzer only to change
the version string it writes (`1.1` → `1.3`).

### 8. Re-apply the current value for every type; change a value only for enums

snapd's "has no 'configure' hook" rejection does not depend on the value, and snapd runs
the `configure` hook on every `snap set`. So the validator's baseline check, which works
for every option type, re-applies one option's current value (`snap get`, then `snap set`
with that value, or `snap unset` when the key is unset). This proves the hook exists and
accepts a valid value without guessing at what the app accepts.

When an `enum` option has another value in `allowed_values`, the validator sets that value
instead, checks that daemons stay active, and then restores the original value. That also
exercises the hook's validation and the restart path. No other type gets a changed value:
a new port can collide, a new integer can change behaviour (worker counts, memory limits),
and paths, strings and booleans have no value that is safe to guess.

*Alternative: pick a changed value per type (unprivileged port, default + 1) and skip
`path`/`string`.* Rejected: snaps whose options are all strings or paths would never be
tested, and guessed values risk false `config-set-failed` results.

## Risks / Trade-offs

- **The analyzer misses a `snapctl get` call** (for example, inside a sourced helper) →
  no option recorded, no hook. Mitigation: the checklist asks for a repository-wide search
  for `snapctl get` and for planned `snapctl set` seeding, and the analyzer records an
  option for any key it plans to seed.
- **Validator picks a value that breaks the app** → false `config-set-failed`.
  Mitigation: only an allowed `enum` value is ever changed; every other check re-applies
  the current value (decision 8).
- **Re-applying a value doesn't test restart behaviour.** Accepted: the check targets the
  missing-hook failure; `value_changed: false` in the results and the final report make
  the narrower coverage visible.
- **`snap unset` on an unset key** runs the `configure` hook like `snap set`. Verified in
  LXD (Ubuntu 24.04): re-setting an unchanged value and unsetting a never-set key both ran
  the hook, and both fail with "has no \"configure\" hook" on a snap without one. No
  fallback is needed.
- **Two `config_options` fields** with overlapping shape. Accepted for now; unifying them
  is a follow-up once the OCI path can be re-tested.
- **Fallback checker growth.** Four more keywords in a hand-rolled checker. Kept small and
  covered by new negative examples in `--self-test`.

## Migration Plan

Additive schemas: older analyses and results still validate, and readers handle missing
fields as before. An older analysis that recorded options without `configure` would now
fail the gate, but no producer could emit top-level options before 1.3, and OCI analyses
already list `configure`. Rollback is reverting the change.

## Open Questions

- Should `config-set-failed` become patchable later (author adds the hook from the
  analysis' `config_options[]`)? Deferred; it needs a snap-builder routing change.
