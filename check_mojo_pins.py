#!/usr/bin/env python3
"""Assert every Mojo version spec in `pixi.toml` agrees.

pixi.toml has no variable interpolation, so the compiler version is written out
three times: once as the `mojo` workspace dependency (the dev environment) and
once as `mojo-compiler` in each of the package's build- and run-dependencies. A
`.mojoc` is tied to the compiler that produced it, so a drifted run-dependency
ships consumers a package their compiler cannot load.
"""

import sys
import tomllib

MANIFEST = "pixi.toml"


def main() -> int:
    with open(MANIFEST, "rb") as f:
        manifest = tomllib.load(f)

    package = manifest["package"]
    pins = {
        "[dependencies].mojo": manifest["dependencies"]["mojo"],
        "[package.build-dependencies].mojo-compiler": package[
            "build-dependencies"
        ]["mojo-compiler"],
        "[package.run-dependencies].mojo-compiler": package[
            "run-dependencies"
        ]["mojo-compiler"],
    }

    if len(set(pins.values())) == 1:
        print(f"mojo pins agree: {next(iter(pins.values()))}")
        return 0

    print(f"{MANIFEST}: mojo version specs disagree", file=sys.stderr)
    for where, spec in pins.items():
        print(f"  {where} = {spec!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
