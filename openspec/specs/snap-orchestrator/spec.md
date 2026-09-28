# snap-orchestrator Specification

## Purpose
Runs the end-to-end snap pipeline (analyze, package, validate, patch, rebuild) by delegating each phase to a focused sub-agent. It owns control flow, iteration limits and the final report. It does not do analysis, packaging or validation itself.

## Requirements

### Requirement: Pre-flight checks
Before delegating any work, the skill SHALL confirm that `lxc` and `snapcraft` are installed and the working directory is not empty. It MUST stop with install instructions or an explanation if any check fails.

#### Scenario: snapcraft missing
- **WHEN** `snapcraft` is not on the PATH
- **THEN** the skill stops and tells the user to run `snap install snapcraft`

### Requirement: Analyzer selection
The skill SHALL run exactly one analyzer per pipeline. It SHALL use `snap-oci-analyzer` when the input is a pre-extracted `config.json` and `rootfs/`, a `.tar` file, or a named image reference or Docker Hub URL, and use `snap-analyzer` otherwise. When the input is ambiguous (both kinds or neither) it MUST ask the user.

#### Scenario: Image reference in the request
- **WHEN** the user asks to package `quay.io/org/app:tag`
- **THEN** `snap-oci-analyzer` is delegated for Phase 1

#### Scenario: Plain source project
- **WHEN** the directory holds source code and no image input
- **THEN** `snap-analyzer` is delegated for Phase 1

### Requirement: Target architecture for source builds
On the source path, the skill SHALL default to the host architecture without asking, unless the request mentions cross-compilation, embedded or IoT hardware, or a specific non-host architecture, in which case it asks once. It SHALL pass the answer to `snap-analyzer`. On the OCI path it MUST skip this step.

#### Scenario: Ordinary request
- **WHEN** the user asks to "package this project as a snap" with no hardware mentioned
- **THEN** no architecture question is asked and the analyzer receives a null target

### Requirement: Clean starting state
The skill SHALL ask whether to reuse or regenerate an existing analysis file, and MUST delete any existing `snap-validation-results.json` before initial packaging and before each validation run.

#### Scenario: Stale results from an earlier run
- **WHEN** `snap-validation-results.json` exists at start
- **THEN** it is deleted before packaging begins

### Requirement: Classic snaps skip validation
If the analysis records `confinement: classic`, the skill SHALL skip the validation and patch loop and go straight to the final report. The report MUST remind the user that the snap needs manual Store approval and will not run on Ubuntu Core.

#### Scenario: Classic confirmed during analysis
- **WHEN** the analysis has `confinement: classic`
- **THEN** no validator run occurs and the final report includes both caveats

### Requirement: Result-driven loop routing
After each validation run the skill SHALL route on the results in this order:
1. Non-empty `diagnostics[]` stops the pipeline and reports them.
2. `devmode_pass: false` sends the snap to the packager's build-fix branch.
3. `clean: true` ends the denial loop.
4. Remaining denials send the snap to the packager's patch mode.

After every patch or fix it SHALL rebuild and validate again.

#### Scenario: Devmode failure
- **WHEN** results have `devmode_pass: false`
- **THEN** the packager is asked for a build fix, not a plug or layout patch, and the denial counter is not incremented

#### Scenario: Diagnostics reported
- **WHEN** results contain diagnostics
- **THEN** the pipeline stops and shows each diagnostic

### Requirement: Independent iteration caps
The skill SHALL cap denial patching at 5 iterations, devmode build fixes at 3, and OCI reproducibility fixes at 3, each counted separately. Hitting a cap MUST end that loop and carry the unresolved items into the final report, not abort the pipeline.

#### Scenario: Denials persist
- **WHEN** the fifth denial patch still leaves denials
- **THEN** the loop ends and the final report lists the remaining denials with troubleshooting steps

### Requirement: OCI reproducibility loop
In OCI mode, once the denial loop is clean, the skill SHALL ask the validator for a reproducibility check. Any diffs go to the packager as override steps, after which the full denial scan runs again before reproducibility is rechecked. A clean result, or `checked: false`, ends the loop.

#### Scenario: Override fix introduces a denial
- **WHEN** a reproducibility fix is applied and the rebuilt snap triggers a new denial
- **THEN** the denial is handled by the denial loop before reproducibility is checked again

### Requirement: Final report
The skill SHALL report:
- snap name, analyzer used, confinement, plugin and target architecture
- iteration counts, devmode status, store-review interfaces and reproducibility status
- the files produced
- the exact `snap connect` command for every interface with `auto_connected: false`
- any unresolved denials or reproducibility diffs

#### Scenario: Store-review interface needed
- **WHEN** results list `docker-support` in `store_review_interfaces[]`
- **THEN** the report warns that the snap needs manual Snap Store review before distribution

### Requirement: Failure handling
The skill MUST stop and show the error when an analyzer fails or writes invalid JSON, when OCI dependencies cannot be installed, when packaging fails after 3 build attempts, when no `.snap` exists after packaging, or when the validator does not write results.

#### Scenario: Invalid analysis
- **WHEN** the analysis file is not valid JSON
- **THEN** the pipeline stops before packaging and shows the error
