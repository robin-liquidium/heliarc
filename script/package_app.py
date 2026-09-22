#!/usr/bin/env python3
"""Build and sign a universal Heliarc application bundle."""

import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path
from sparkle import embed_and_sign, plist_settings

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "dist" / "release"
APP = OUT / "Heliarc.app"
DEVELOPER_ID = "Developer ID Application: Robin Obermaier (5S5288W3R7)"


def run(*args: object, capture: bool = False) -> str:
    environment = os.environ.copy()
    stable_xcode = Path("/Applications/Xcode.app/Contents/Developer")
    if stable_xcode.exists():
        environment.setdefault("DEVELOPER_DIR", str(stable_xcode))
    result = subprocess.run(
        list(map(str, args)),
        check=True,
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout or ""


def package() -> Path:
    metadata = json.loads((ROOT / "release.json").read_text())
    identity = os.environ.get("SIGNING_IDENTITY", "-")
    build = ["swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64"]
    run(*build)
    binary_dir = Path(run(*build, "--show-bin-path", capture=True).strip())

    shutil.rmtree(APP, ignore_errors=True)
    resources = APP / "Contents" / "Resources"
    resources.mkdir(parents=True)
    executable = APP / "Contents" / "MacOS" / "Heliarc"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary_dir / "Heliarc", executable)
    if set(run("lipo", "-archs", executable, capture=True).split()) != {"arm64", "x86_64"}:
        raise RuntimeError("Expected a universal arm64 and x86_64 executable")

    icon_info = OUT / "icon-info.plist"
    run(
        "xcrun",
        "actool",
        ROOT / "Resources" / "HeliarcIcon.icon",
        "--compile",
        resources,
        "--output-partial-info-plist",
        icon_info,
        "--app-icon",
        "HeliarcIcon",
        "--minimum-deployment-target",
        "14.0",
        "--platform",
        "macosx",
    )
    icon_info.unlink(missing_ok=True)
    for name in ["HeliarcIcon.png", "HeliarcLogo.png", "MenuBarIcon@2x.png"]:
        shutil.copy2(ROOT / "Resources" / name, resources / name)
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")

    info = {
        "CFBundleExecutable": "Heliarc",
        "CFBundleIdentifier": "build.robin.heliarc",
        "CFBundleName": "Heliarc",
        "CFBundleDisplayName": "Heliarc",
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "HeliarcIcon",
        "CFBundleIconName": "HeliarcIcon",
        "CFBundleShortVersionString": metadata["version"],
        "CFBundleVersion": str(metadata["build"]),
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
        "NSAppleEventsUsageDescription": "Heliarc tracks the active Helium tab for recent-tab ordering and activates tabs when you use Ctrl-Tab.",
    }
    with (APP / "Contents" / "Info.plist").open("wb") as output:
        info.update(plist_settings())
        plistlib.dump(info, output)

    embed_and_sign(APP, identity)
    options = ["--timestamp", "--options", "runtime"] if identity != "-" else ["--timestamp=none"]
    run("codesign", "--force", *options, "--sign", identity, "--entitlements", ROOT / "entitlements.plist", APP)
    run("codesign", "--verify", "--deep", "--strict", APP)
    if identity != "-" and identity != DEVELOPER_ID:
        print(f"Warning: signed with non-default identity: {identity}")
    return APP


if __name__ == "__main__":
    print(package())
