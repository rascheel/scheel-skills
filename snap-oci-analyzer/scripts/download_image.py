#!/usr/bin/env python3
"""
Download a Docker/OCI image reference or Docker Hub URL as a docker-archive tarball.

The script intentionally uses skopeo so no local Docker daemon is required.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse


DEFAULT_TAG = "latest"


def docker_hub_path_to_ref(path: str, query: str) -> str:
    parts = [part for part in path.strip("/").split("/") if part]
    params = parse_qs(query)
    tag = params.get("tag", params.get("name", [DEFAULT_TAG]))[0] or DEFAULT_TAG

    if len(parts) >= 2 and parts[0] == "_":
        return f"docker.io/library/{parts[1]}:{tag}"

    if len(parts) >= 3 and parts[0] == "r":
        return f"docker.io/{parts[1]}/{parts[2]}:{tag}"

    if len(parts) >= 5 and parts[0] == "layers":
        image_parts = parts[1:-1]
        tag = parts[-1] or tag
        if len(image_parts) == 1:
            return f"docker.io/library/{image_parts[0]}:{tag}"
        return f"docker.io/{'/'.join(image_parts)}:{tag}"

    raise ValueError(
        "unsupported Docker Hub URL. Expected /_/name, /r/namespace/name, "
        "or /layers/.../<tag>"
    )


def normalize_image_ref(source: str) -> str:
    parsed = urlparse(source)
    if parsed.scheme in {"http", "https"}:
        host = parsed.netloc.lower()
        if host in {"hub.docker.com", "www.hub.docker.com"}:
            return docker_hub_path_to_ref(parsed.path, parsed.query)
        raise ValueError(f"unsupported image URL host: {parsed.netloc}")

    if source.startswith("docker://"):
        source = source[len("docker://") :]

    if "/" not in source.split(":", 1)[0] and "/" not in source:
        source = f"docker.io/library/{source}"
    elif "/" in source and "." not in source.split("/", 1)[0] and ":" not in source.split("/", 1)[0]:
        source = f"docker.io/{source}"

    last_segment = source.rsplit("/", 1)[-1]
    if ":" not in last_segment and "@" not in last_segment:
        source = f"{source}:{DEFAULT_TAG}"

    return source


def default_output_path(image_ref: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", image_ref).strip("_")
    return Path(f"{safe}.tar")


def run_skopeo(image_ref: str, output: Path, dry_run: bool) -> None:
    if shutil.which("skopeo") is None:
        raise RuntimeError("skopeo is not installed; run scripts/ensure_dependencies.py --install -y")

    command = [
        "skopeo",
        "copy",
        f"docker://{image_ref}",
        f"docker-archive:{output}:{image_ref}",
    ]
    if dry_run:
        print(" ".join(command))
        return
    subprocess.run(command, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Download a Docker Hub URL or image reference to a docker-archive tarball."
    )
    parser.add_argument("source", help="Docker Hub URL, docker:// reference, or image reference")
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="Output tarball path. Defaults to a sanitized image reference plus .tar.",
    )
    parser.add_argument(
        "--print-ref",
        action="store_true",
        help="Only print the normalized image reference; do not download.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the skopeo command without downloading.",
    )
    args = parser.parse_args()

    try:
        image_ref = normalize_image_ref(args.source)
        output = args.output or default_output_path(image_ref)
        if args.print_ref:
            print(image_ref)
            return 0
        run_skopeo(image_ref, output, args.dry_run)
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
