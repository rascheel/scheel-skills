#!/usr/bin/env python3
"""Regression tests for the Snapcraft manifest patcher."""

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "patch_snapcraft.py"
SPEC = importlib.util.spec_from_file_location("patch_snapcraft", SCRIPT)
patch_snapcraft = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(patch_snapcraft)


class PatchOverrideStepsTests(unittest.TestCase):
    def test_new_override_steps_start_with_craftctl_default(self):
        manifest = {"parts": {"app": {"plugin": "dump"}}}

        patch_snapcraft.patch_override_steps(
            manifest,
            "app",
            ["chmod 755 $CRAFT_PART_INSTALL/usr/bin/app"],
            ["rm -f $CRAFT_PRIME/usr/share/doc/unneeded"],
        )

        part = manifest["parts"]["app"]
        self.assertTrue(part["override-build"].startswith("craftctl default\n"))
        self.assertTrue(part["override-prime"].startswith("craftctl default\n"))


if __name__ == "__main__":
    unittest.main()
