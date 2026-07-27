#!/usr/bin/env python3
"""
Ensure host dependencies required by the snap-oci-container skill are present.

By default the script reports missing dependencies and exits non-zero. Pass
--install to install missing Ubuntu/Debian packages with apt-get.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys


COMMAND_PACKAGES = {
    "tar": "tar",
    "skopeo": "skopeo",
    "umoci": "umoci",
    "jq": "jq",
}

PYTHON_MODULE_PACKAGES = {
    "ruamel.yaml": "python3-ruamel.yaml",
}


def missing_commands() -> list[str]:
    return [command for command in COMMAND_PACKAGES if shutil.which(command) is None]


def missing_python_modules() -> list[str]:
    missing: list[str] = []
    for module in PYTHON_MODULE_PACKAGES:
        try:
            __import__(module)
        except ImportError:
            missing.append(module)
    return missing


def apt_get_available() -> bool:
    return shutil.which("apt-get") is not None


def command_runner() -> list[str]:
    if os.geteuid() == 0:
        return []
    sudo = shutil.which("sudo")
    if sudo:
        return [sudo]
    raise RuntimeError("missing dependencies require installation, but neither root nor sudo is available")


def install_packages(packages: list[str], assume_yes: bool) -> None:
    if not apt_get_available():
        raise RuntimeError(
            "automatic installation currently supports apt-get systems only; "
            f"install these packages manually: {' '.join(packages)}"
        )

    prefix = command_runner()
    yes_flag = ["-y"] if assume_yes else []
    subprocess.run(prefix + ["apt-get", "update"], check=True)
    subprocess.run(prefix + ["apt-get", "install", *yes_flag, *packages], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check and optionally install dependencies for snap-oci-container."
    )
    parser.add_argument(
        "--install",
        action="store_true",
        help="Install missing packages on apt-get based systems.",
    )
    parser.add_argument(
        "-y",
        "--assume-yes",
        action="store_true",
        help="Pass -y to apt-get install when used with --install.",
    )
    args = parser.parse_args()

    commands = missing_commands()
    modules = missing_python_modules()
    if not commands and not modules:
        print("All snap-oci-container dependencies are installed.")
        return 0

    packages = sorted(
        {COMMAND_PACKAGES[command] for command in commands}
        | {PYTHON_MODULE_PACKAGES[module] for module in modules}
    )

    print("Missing snap-oci-container dependencies:", file=sys.stderr)
    for command in commands:
        print(f"  command: {command} (apt package: {COMMAND_PACKAGES[command]})", file=sys.stderr)
    for module in modules:
        print(
            f"  python module: {module} (apt package: {PYTHON_MODULE_PACKAGES[module]})",
            file=sys.stderr,
        )

    if not args.install:
        print(
            "\nRun this script again with --install to install missing apt packages:",
            file=sys.stderr,
        )
        print(
            "  python3 scripts/ensure_dependencies.py --install -y",
            file=sys.stderr,
        )
        return 1

    try:
        install_packages(packages, args.assume_yes)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: dependency installation failed: {exc}", file=sys.stderr)
        return 2

    remaining_commands = missing_commands()
    remaining_modules = missing_python_modules()
    if remaining_commands or remaining_modules:
        print("ERROR: dependencies are still missing after installation:", file=sys.stderr)
        for command in remaining_commands:
            print(f"  command: {command}", file=sys.stderr)
        for module in remaining_modules:
            print(f"  python module: {module}", file=sys.stderr)
        return 3

    print("Installed all snap-oci-container dependencies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
