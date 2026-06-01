#!/usr/bin/env python3
"""Walk `test/` and run each `test_*.mojo` file as its own `mojo` invocation.

Each test file is a standalone program that runs a `TestSuite`. Helper modules
(anything not matching `test_*.mojo`, e.g. `_debug_format.mojo`) are importable
because the test directory is on the import path, but are not executed directly.
"""

import os
import subprocess
import sys

TEST_DIR = "test"


def main() -> int:
    test_files = []
    for root, _dirs, files in os.walk(TEST_DIR):
        for name in sorted(files):
            if name.startswith("test_") and name.endswith(".mojo"):
                test_files.append(os.path.join(root, name))

    if not test_files:
        print("no tests")
        return 0

    failed = []
    for path in test_files:
        print(f"==> {path}")
        result = subprocess.run(
            [
                "mojo",
                "run",
                "-D",
                "ASSERT=all",
                "-I",
                ".",
                "-I",
                TEST_DIR,
                path,
            ]
        )
        if result.returncode != 0:
            failed.append(path)

    print()
    if failed:
        print(f"FAILED ({len(failed)}/{len(test_files)}):")
        for path in failed:
            print(f"  {path}")
        return 1

    print(f"All {len(test_files)} test files passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
