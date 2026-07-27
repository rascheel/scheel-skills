#!/usr/bin/env python3
"""
patch_snapcraft.py — Adds OCI-derived plugs, layouts, and override steps to an
                     existing snapcraft.yaml.

Usage:
    python3 scripts/patch_snapcraft.py \\
        --snapcraft snap/snapcraft.yaml \\
        --app my-app \\
        --plugs network network-bind hardware-observe \\
        --layout /var/lib/myapp '$SNAP_COMMON/myapp' \\
        --layout /usr/lib/mylib '$SNAP/lib/mylib'

    # Add override-build commands to a part (encodes rootfs modifications):
    python3 scripts/patch_snapcraft.py \\
        --snapcraft snap/snapcraft.yaml \\
        --part oci-container \\
        --override-build "patchelf --set-interpreter \\$SNAPCRAFT_PART_INSTALL/lib/ld.so \\$SNAPCRAFT_PART_INSTALL/usr/bin/myapp" \\
        --override-build "chmod 755 \\$SNAPCRAFT_PART_INSTALL/usr/bin/myapp"

Options:
    --snapcraft PATH       Path to snapcraft.yaml (auto-detected if omitted)
    --app NAME             App to add plugs to (uses first app found if omitted)
    --plugs NAME ...       One or more snap interface names to add as plugs
    --layout PATH BIND     Add a layout entry binding PATH to BIND (repeatable)
    --part NAME            Part name to add override steps to (required with --override-*)
    --override-build CMD   Shell command to append to override-build for --part (repeatable)
    --override-prime CMD   Shell command to append to override-prime for --part (repeatable)
    --dry-run              Print the patched YAML without writing to disk
    --no-backup            Skip creating the .bak backup file

Exit codes:
    0  Success (or --dry-run completed)
    1  snapcraft.yaml not found or unreadable
    2  Named --app not found in snapcraft.yaml
    3  YAML parse error
    4  Missing required arguments (need at least --plugs, --layout, --override-build,
       or --override-prime)
    5  Named --part not found in the parts section of snapcraft.yaml
    6  --override-build or --override-prime used without --part

Layout target paths that violate the snapcraft layouts specification are
skipped with a WARNING rather than causing a hard failure. Forbidden paths
are listed in references/layout-constraints.md.

Override steps:
    --override-build appends shell commands after snapcraftctl build in the named
    part's override-build key.  --override-prime does the same for override-prime.
    snapcraftctl build / snapcraftctl prime are inserted automatically if not already
    present.  Commands already present in the step are skipped (idempotent).

    See references/override-steps-guide.md for pattern examples covering ELF
    interpreter patching, symlink creation, permission changes, config mutations,
    and more.

WARNING: this script uses PyYAML which does not preserve comments or custom
         formatting. A .bak backup is created before writing by default.
         Use 'diff snapcraft.yaml.bak snapcraft.yaml' to review changes.
"""

import argparse
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# YAML backend — prefer ruamel.yaml (preserves comments), fall back to PyYAML
# ---------------------------------------------------------------------------
try:
    from ruamel.yaml import YAML as _RYAML

    _ruamel_available = True

    def _load_yaml(text: str):
        ry = _RYAML()
        ry.preserve_quotes = True
        return ry.load(text), ry

    def _dump_yaml(data, stream, backend) -> None:
        backend.dump(data, stream)

except ImportError:
    _ruamel_available = False
    try:
        import yaml as _pyyaml


        def _load_yaml(text: str):  # type: ignore[misc]
            return _pyyaml.safe_load(text), None

        def _dump_yaml(data, stream, backend) -> None:  # type: ignore[misc]
            _pyyaml.dump(data, stream, default_flow_style=False, allow_unicode=True, sort_keys=False)

    except ImportError:
        print(
            "ERROR: Neither ruamel.yaml nor PyYAML is installed.\n"
            "  Install one with:  pip install ruamel.yaml\n"
            "  or:                pip install pyyaml",
            file=sys.stderr,
        )
        sys.exit(1)


def _make_block_scalar(text: str):
    """
    Return *text* wrapped in a ruamel.yaml LiteralScalarString so that it is
    serialised with the ``|`` block style.  Falls back to a plain str when
    ruamel.yaml is not available (PyYAML renders multi-line strings as block
    scalars automatically when they contain newlines).
    """
    if _ruamel_available:
        from ruamel.yaml.scalarstring import LiteralScalarString
        return LiteralScalarString(text)
    return text


# ---------------------------------------------------------------------------
# Layout target path validation
# Source: https://documentation.ubuntu.com/snapcraft/stable/reference/layouts/#requirements
# ---------------------------------------------------------------------------

# Paths explicitly forbidden by the snapcraft layouts specification.
FORBIDDEN_LAYOUT_TARGETS: frozenset[str] = frozenset([
    "/boot",
    "/dev",
    "/home",
    "/lib/firmware",
    "/usr/lib/firmware",
    "/lib/modules",
    "/usr/lib/modules",
    "/lost+found",
    "/media",
    "/proc",
    "/run",
    "/var/run",
    "/sys",
    "/tmp",
    "/var/lib/snapd",
    "/var/snap",
])


def validate_layout_target(path: str) -> list[str]:
    """
    Return a list of human-readable violation strings for the given layout
    target path.  An empty list means the path is valid.

    Rules enforced:
      1. Path must be absolute (starts with '/').
      2. Path must not exactly match or be a subdirectory of any entry in
         FORBIDDEN_LAYOUT_TARGETS (the denylist applies to the entire subtree).
      3. Path must not be a direct child of '/' (depth == 1 component).
    """
    errors: list[str] = []

    if not path.startswith("/"):
        errors.append(f"  '{path}': not an absolute path — must start with '/'.")
        return errors  # remaining checks require absolute path

    for forbidden in FORBIDDEN_LAYOUT_TARGETS:
        if path == forbidden or path.startswith(forbidden + "/"):
            errors.append(
                f"  '{path}': falls within the snapcraft layouts denylist entry '{forbidden}'.\n"
                "    The denylist applies to the listed paths and all their subdirectories.\n"
                "    See references/layout-constraints.md §2 for the full list and §4 for workarounds."
            )
            break  # one match is enough

    components = [p for p in path.split("/") if p]
    if len(components) == 1:
        errors.append(
            f"  '{path}': is a direct child of '/' — root-level layout targets are not allowed.\n"
            "    See references/layout-constraints.md §4 for workarounds (patchelf, env-var overrides)."
        )

    return errors


def filter_valid_layouts(layouts: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """
    Return only the layout pairs whose target path is valid.
    Invalid targets are printed as WARNINGs and silently dropped so the script
    can still apply the remaining (valid) entries.
    """
    valid: list[tuple[str, str]] = []
    for dest, bind in layouts:
        errors = validate_layout_target(dest)
        if errors:
            print(
                f"WARNING: Skipping layout '{dest}' — invalid target path:\n"
                + "\n".join(errors)
                + "\n  If the application lets you configure this path (e.g. via an"
                + "\n  environment variable or config file), you can ignore this warning"
                + "\n  and redirect the path at runtime instead:"
                + "\n    - For writable paths: point to $SNAP_COMMON/<subpath> (persists"
                + "\n      across upgrades) or $HOME/<subpath> (per-user, needs home plug)."
                + "\n    - For read-only paths shipped in the snap: point to $SNAP/<subpath>."
                + "\n  Otherwise, consult references/layout-constraints.md for alternatives.",
                file=sys.stderr,
            )
        else:
            valid.append((dest, bind))
    return valid


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CANDIDATE_PATHS = [
    "snapcraft.yaml",
    "snap/snapcraft.yaml",
    ".snapcraft.yaml",
]


def find_snapcraft(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not p.is_file():
            print(f"ERROR: snapcraft.yaml not found at: {explicit}", file=sys.stderr)
            sys.exit(1)
        return p
    for candidate in CANDIDATE_PATHS:
        p = Path(candidate)
        if p.is_file():
            return p
    print(
        "ERROR: Could not find snapcraft.yaml. Tried:\n"
        + "\n".join(f"  {c}" for c in CANDIDATE_PATHS)
        + "\nPass --snapcraft <path> to specify the location.",
        file=sys.stderr,
    )
    sys.exit(1)


def ensure_list(obj, key: str) -> list:
    """Return obj[key] as a list, creating it if absent."""
    if key not in obj or obj[key] is None:
        obj[key] = []
    elif not isinstance(obj[key], list):
        # Shouldn't happen in valid snapcraft.yaml but be safe
        obj[key] = list(obj[key])
    return obj[key]


def ensure_dict(obj, key: str) -> dict:
    """Return obj[key] as a dict, creating it if absent."""
    if key not in obj or obj[key] is None:
        obj[key] = {}
    return obj[key]


# ---------------------------------------------------------------------------
# Core patch logic
# ---------------------------------------------------------------------------

def patch(data: dict, app_name: str | None, plugs: list[str], layouts: list[tuple[str, str]]) -> tuple[list[str], list[str]]:
    """
    Mutate *data* in-place, adding plugs and layout entries.

    Returns (added_plugs, added_layouts) — the items actually inserted
    (already-present items are silently skipped).
    """
    apps = data.get("apps", {})
    if not apps:
        print("ERROR: snapcraft.yaml has no 'apps' section.", file=sys.stderr)
        sys.exit(2)

    # Resolve app name
    if app_name is None:
        app_name = next(iter(apps))
        print(f"INFO: --app not specified, using first app: '{app_name}'", file=sys.stderr)
    elif app_name not in apps:
        available = ", ".join(apps.keys())
        print(
            f"ERROR: App '{app_name}' not found in snapcraft.yaml.\n"
            f"  Available apps: {available}",
            file=sys.stderr,
        )
        sys.exit(2)

    app = apps[app_name]

    # --- Add plugs ---
    added_plugs: list[str] = []
    if plugs:
        current_plugs = ensure_list(app, "plugs")
        for plug in plugs:
            if plug not in current_plugs:
                current_plugs.append(plug)
                added_plugs.append(plug)

    # --- Add layouts ---
    added_layouts: list[str] = []
    if layouts:
        top_layout = ensure_dict(data, "layout")
        for dest, bind_target in layouts:
            if dest in top_layout:
                print(f"INFO: layout '{dest}' already present — skipping.", file=sys.stderr)
            else:
                top_layout[dest] = {"bind": bind_target}
                added_layouts.append(dest)

    return added_plugs, added_layouts


# ---------------------------------------------------------------------------
# Override-step patch logic
# ---------------------------------------------------------------------------

_OVERRIDE_CTL_CALL = {
    "override-build": "snapcraftctl build",
    "override-prime": "snapcraftctl prime",
}


def patch_override_steps(
    data: dict,
    part_name: str,
    override_build_cmds: list[str],
    override_prime_cmds: list[str],
) -> tuple[list[str], list[str]]:
    """
    Append shell commands to the override-build / override-prime keys of *part_name*.

    For each override key:
      - If the key does not exist, create it with ``snapcraftctl build`` (or
        ``snapcraftctl prime``) as the first line, followed by the new commands.
      - If the key already exists, ensure the snapcraftctl call is present as
        the first line, then append only the commands not already present.

    Returns (added_build_cmds, added_prime_cmds) — commands actually inserted.
    Commands already present in the step are silently skipped (idempotent).
    """
    parts = data.get("parts")
    if not parts:
        print("ERROR: snapcraft.yaml has no 'parts' section.", file=sys.stderr)
        sys.exit(5)

    if part_name not in parts:
        available = ", ".join(parts.keys())
        print(
            f"ERROR: Part '{part_name}' not found in snapcraft.yaml.\n"
            f"  Available parts: {available}",
            file=sys.stderr,
        )
        sys.exit(5)

    part = parts[part_name]

    def _apply(cmds: list[str], step_key: str) -> list[str]:
        """Apply *cmds* to *step_key* in *part*.  Returns commands actually added."""
        if not cmds:
            return []
        ctl_call = _OVERRIDE_CTL_CALL[step_key]
        existing_raw: str | None = part.get(step_key)

        if existing_raw is None:
            # Create fresh step: ctl call first, then all new commands.
            lines = [ctl_call] + cmds
            part[step_key] = _make_block_scalar("\n".join(lines) + "\n")
            return list(cmds)

        # Parse existing step and append missing commands.
        existing_lines = existing_raw.splitlines()
        # Ensure snapcraftctl call is the first line.
        if ctl_call not in existing_lines:
            existing_lines.insert(0, ctl_call)

        added: list[str] = []
        for cmd in cmds:
            if cmd not in existing_lines:
                existing_lines.append(cmd)
                added.append(cmd)
            else:
                print(f"INFO: override step command already present — skipping: {cmd!r}", file=sys.stderr)

        part[step_key] = _make_block_scalar("\n".join(existing_lines) + "\n")
        return added

    added_build = _apply(override_build_cmds, "override-build")
    added_prime = _apply(override_prime_cmds, "override-prime")
    return added_build, added_prime

class LayoutAction(argparse.Action):
    """Collect --layout PATH BIND pairs into a list of (path, bind) tuples."""

    def __call__(self, parser, namespace, values, option_string=None):
        items = getattr(namespace, self.dest, None) or []
        items.append(tuple(values))
        setattr(namespace, self.dest, items)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Patch snapcraft.yaml with OCI-derived plugs, layout entries, and override steps.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--snapcraft", metavar="PATH", help="Path to snapcraft.yaml (auto-detected if omitted)")
    p.add_argument("--app", metavar="NAME", help="App name to add plugs to (uses first app if omitted)")
    p.add_argument("--plugs", nargs="+", metavar="NAME", default=[], help="Snap interface names to add as plugs")
    p.add_argument(
        "--layout",
        nargs=2,
        metavar=("PATH", "BIND"),
        action=LayoutAction,
        dest="layouts",
        default=[],
        help="Add a layout entry: --layout /dest $SNAP/src  (repeatable)",
    )
    p.add_argument(
        "--part",
        metavar="NAME",
        help="Part name to add override steps to (required with --override-build / --override-prime)",
    )
    p.add_argument(
        "--override-build",
        metavar="CMD",
        action="append",
        dest="override_build",
        default=[],
        help="Shell command to append to override-build for --part (repeatable)",
    )
    p.add_argument(
        "--override-prime",
        metavar="CMD",
        action="append",
        dest="override_prime",
        default=[],
        help="Shell command to append to override-prime for --part (repeatable)",
    )
    p.add_argument("--dry-run", action="store_true", help="Print patched YAML without writing")
    p.add_argument("--no-backup", action="store_true", help="Skip .bak backup")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    has_plugs_or_layouts = bool(args.plugs or args.layouts)
    has_override = bool(args.override_build or args.override_prime)

    if not has_plugs_or_layouts and not has_override:
        print(
            "ERROR: Provide at least one of --plugs, --layout, --override-build, or --override-prime.",
            file=sys.stderr,
        )
        sys.exit(4)

    if has_override and not args.part:
        print(
            "ERROR: --part is required when using --override-build or --override-prime.\n"
            "  Specify the snapcraft part that contains the rootfs source, e.g.:\n"
            "    --part oci-container",
            file=sys.stderr,
        )
        sys.exit(6)

    # Filter layout targets — invalid ones are warned and skipped.
    if args.layouts:
        args.layouts = filter_valid_layouts(args.layouts)

    snapcraft_path = find_snapcraft(args.snapcraft)
    raw = snapcraft_path.read_text(encoding="utf-8")

    try:
        data, backend = _load_yaml(raw)
    except Exception as exc:
        print(f"ERROR: Failed to parse {snapcraft_path}: {exc}", file=sys.stderr)
        sys.exit(3)

    if not _ruamel_available:
        print(
            "WARNING: ruamel.yaml not found; using PyYAML. Comments and custom "
            "formatting will not be preserved.\n"
            "  Install ruamel.yaml for lossless editing:  pip install ruamel.yaml",
            file=sys.stderr,
        )

    added_plugs, added_layouts = patch(data, args.app, args.plugs, args.layouts)
    added_build_cmds, added_prime_cmds = patch_override_steps(
        data, args.part, args.override_build, args.override_prime
    ) if has_override else ([], [])

    # Serialise
    import io
    buf = io.StringIO()
    _dump_yaml(data, buf, backend)
    patched_yaml = buf.getvalue()

    if args.dry_run:
        print(patched_yaml)
        print(f"\n# Dry run — {snapcraft_path} was NOT modified.", file=sys.stderr)
        return

    # Backup
    if not args.no_backup:
        backup = snapcraft_path.with_suffix(snapcraft_path.suffix + ".bak")
        shutil.copy2(snapcraft_path, backup)
        print(f"INFO: Backup saved to {backup}", file=sys.stderr)

    snapcraft_path.write_text(patched_yaml, encoding="utf-8")

    # Report
    print(f"SUCCESS: Patched {snapcraft_path}")
    if added_plugs:
        print(f"  Added plugs:            {', '.join(added_plugs)}")
    if added_layouts:
        print(f"  Added layouts:          {', '.join(added_layouts)}")
    if added_build_cmds:
        print(f"  Added override-build:   {len(added_build_cmds)} command(s) to part '{args.part}'")
        for cmd in added_build_cmds:
            print(f"    + {cmd}")
    if added_prime_cmds:
        print(f"  Added override-prime:   {len(added_prime_cmds)} command(s) to part '{args.part}'")
        for cmd in added_prime_cmds:
            print(f"    + {cmd}")
    skipped_plugs = [p for p in args.plugs if p not in added_plugs]
    skipped_layouts = [d for d, _ in args.layouts if d not in added_layouts]
    if skipped_plugs:
        print(f"  Already present (skipped): plugs — {', '.join(skipped_plugs)}")
    if skipped_layouts:
        print(f"  Already present (skipped): layouts — {', '.join(skipped_layouts)}")


if __name__ == "__main__":
    main()
