#!/usr/bin/env python3
"""
validate_contracts.py — LXD-free contract gate for the snap-orchestrator pipeline.

Validates snap-analysis.json and snap-validation-results.json against the documented
schema 1.1 shapes. It is the living definition of the "additive, optional-field" promise
between snap-analyzer / snap-oci-analyzer, snap-packager, and snap-validator.

Usage:
    # Validate the bundled examples (OCI-populated and source-case):
    python3 validate_contracts.py --self-test

    # Validate real pipeline artifacts:
    python3 validate_contracts.py \
        --analysis /tmp/snap-analysis-myproj.json \
        --results  snap-validation-results.json

Exit codes: 0 all valid · 1 a validation error · 2 usage / file error.

Prefers the `jsonschema` library when installed; otherwise falls back to a minimal
built-in structural checker so the gate runs in CI/pre-commit with no extra deps.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYSIS_SCHEMA = os.path.join(HERE, "snap-analysis.schema.json")
RESULTS_SCHEMA = os.path.join(HERE, "snap-validation-results.schema.json")


def _load(path):
    with open(path) as fh:
        return json.load(fh)


def _validate_with_jsonschema(instance, schema):
    import jsonschema  # type: ignore

    jsonschema.validate(instance=instance, schema=schema)
    return []


def _fallback_check(instance, schema, path="$"):
    """Minimal draft-07 subset: required, type, enum, nested properties/items.

    Not a full validator — it catches the structural breakages this gate cares about
    (missing required keys, wrong scalar types, bad enum values) without a dependency.
    """
    errors = []
    t = schema.get("type")
    type_map = {
        "object": dict,
        "array": list,
        "string": str,
        "integer": int,
        "boolean": bool,
        "number": (int, float),
        "null": type(None),
    }
    if t is not None:
        types = t if isinstance(t, list) else [t]
        py = tuple(type_map[x] for x in types if x in type_map)
        # bool is a subclass of int — guard so True/False do not pass "integer"
        ok = isinstance(instance, py) and not (
            isinstance(instance, bool) and "boolean" not in types and int in py
        )
        if not ok:
            errors.append(f"{path}: expected type {types}, got {type(instance).__name__}")
            return errors

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} not in enum {schema['enum']}")

    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                errors.append(f"{path}: missing required key '{req}'")
        props = schema.get("properties", {})
        for key, subschema in props.items():
            if key in instance:
                errors += _fallback_check(instance[key], subschema, f"{path}.{key}")

    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            errors += _fallback_check(item, schema["items"], f"{path}[{i}]")

    return errors


def validate(instance, schema, label):
    try:
        _validate_with_jsonschema(instance, schema)
        engine = "jsonschema"
        errors = []
    except ImportError:
        engine = "fallback"
        errors = _fallback_check(instance, schema)
    except Exception as exc:  # jsonschema.ValidationError and friends
        engine = "jsonschema"
        errors = [str(exc).splitlines()[0]]

    if errors:
        print(f"FAIL  {label}  ({engine})")
        for e in errors:
            print(f"      - {e}")
        return False
    print(f"ok    {label}  ({engine})")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--analysis", metavar="PATH", help="snap-analysis.json to validate")
    ap.add_argument("--results", metavar="PATH", help="snap-validation-results.json to validate")
    ap.add_argument("--self-test", action="store_true", help="Validate the bundled examples")
    args = ap.parse_args()

    if not (args.analysis or args.results or args.self_test):
        ap.print_help()
        return 2

    try:
        analysis_schema = _load(ANALYSIS_SCHEMA)
        results_schema = _load(RESULTS_SCHEMA)
    except OSError as exc:
        print(f"ERROR: cannot read schema files: {exc}", file=sys.stderr)
        return 2

    all_ok = True
    checks = []

    if args.self_test:
        ex = os.path.join(HERE, "examples")
        checks += [
            (os.path.join(ex, "snap-analysis.oci.json"), analysis_schema, "analysis (oci)"),
            (os.path.join(ex, "snap-analysis.source.json"), analysis_schema, "analysis (source)"),
            (os.path.join(ex, "snap-validation-results.oci.json"), results_schema, "results (oci)"),
            (os.path.join(ex, "snap-validation-results.source.json"), results_schema, "results (source)"),
            (os.path.join(ex, "snap-validation-results.failure.json"), results_schema, "results (failure)"),
        ]
    if args.analysis:
        checks.append((args.analysis, analysis_schema, f"analysis ({args.analysis})"))
    if args.results:
        checks.append((args.results, results_schema, f"results ({args.results})"))

    for path, schema, label in checks:
        try:
            instance = _load(path)
        except OSError as exc:
            print(f"FAIL  {label}: {exc}")
            all_ok = False
            continue
        except json.JSONDecodeError as exc:
            print(f"FAIL  {label}: invalid JSON — {exc}")
            all_ok = False
            continue
        if not validate(instance, schema, label):
            all_ok = False

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
