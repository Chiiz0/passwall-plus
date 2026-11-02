#!/usr/bin/env python3
"""Ensure newer extension packages cannot replace or delete the main APK."""
from pathlib import Path
import os
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "scripts/build-firmware.sh").read_text()
function = source[source.index("copy_built_package() {"):source.index("for command_name in")]

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    packages = root / "sdk/bin/packages/x86_64/passwall_plus"
    packages.mkdir(parents=True)
    imagebuilder = root / "imagebuilder/packages"
    imagebuilder.mkdir(parents=True)
    dist = root / "dist"
    dist.mkdir()
    names = ["luci-app-passwall-26.10.29-r2.apk", "luci-app-passwall-ezcnet-0.2.0-r1.apk"]
    for index, name in enumerate(names):
        path = packages / name
        path.write_text(name)
        os.utime(path, (100 + index, 100 + index))
    env = dict(os.environ, SDK_DIR=str(root / "sdk"), IMAGEBUILDER_DIR=str(root / "imagebuilder"),
               DIST_DIR=str(dist), OPENWRT_ARCH="x86_64")
    # Copy the extension first too, to check that main-package cleanup preserves it.
    commands = "\ncopy_built_package luci-app-passwall-ezcnet\ncopy_built_package luci-app-passwall\n"
    subprocess.run(["bash", "-eu"], input=function + commands, text=True, env=env, check=True)
    for directory in [imagebuilder, dist]:
        assert sorted(path.name for path in directory.iterdir()) == names
        for name in names:
            assert (directory / name).read_text() == name
print("Package copy checks passed: exact package selection and extension preservation")
