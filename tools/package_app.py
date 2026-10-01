#!/usr/bin/env python3
"""Build and locally sign the standalone macOS Stage C app; no installation or login registration."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD_ENV = dict(os.environ)
BUILD_ENV.setdefault("CLANG_MODULE_CACHE_PATH", str(ROOT / ".local/compiler-cache"))
BUILD_ENV.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", str(ROOT / ".local/compiler-cache"))

def run(*args):
    subprocess.run(args, cwd=ROOT, env=BUILD_ENV, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", default="-", help="codesign identity; default ad-hoc, not distribution signing")
    parser.add_argument("--output", type=Path, default=ROOT / ".local/StageC/Zapas.app", help="Build output inside this repository .local; lets a running build remain untouched")
    args = parser.parse_args()
    scratch = ROOT / ".local/release-build"
    run("swift", "build", "-c", "release", "--scratch-path", str(scratch))
    binaries = Path(subprocess.check_output(["swift", "build", "-c", "release", "--scratch-path", str(scratch), "--show-bin-path"], cwd=ROOT, env=BUILD_ENV, text=True).strip())
    app = args.output.resolve()
    if not app.is_relative_to((ROOT / ".local").resolve()) or app.name != "Zapas.app":
        parser.error("--output must name Zapas.app inside this repository .local")
    if app.exists():
        # Only an explicitly selected ignored build output is replaced; never an installed app.
        shutil.rmtree(app)
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    # Zapas/zapas would collide on the default case-insensitive macOS filesystem.
    for source, target in [("ZapasApp", "ZapasApp"), ("zapas", "zapas"), ("zapas-native-host", "zapas-native-host")]:
        shutil.copy2(binaries / source, macos / target)
    shutil.copytree(ROOT / "chrome-production", resources / "chrome-extension", ignore=shutil.ignore_patterns("*.test.mjs"))
    plist = {
        "CFBundleIdentifier": "com.stubbs221.Zapas",
        "CFBundleName": "Zapas", "CFBundleDisplayName": "Zapas",
        "CFBundleExecutable": "ZapasApp", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "3",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "CFBundleDevelopmentRegion": "ru", "CFBundleLocalizations": ["ru"],
    }
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(plist, file)
    (resources / "About.txt").write_text("Zapas 0.3.0 — локальная диагностика памяти. История только в памяти.\n", encoding="utf-8")
    run("codesign", "--force", "--sign", args.identity, str(macos / "zapas"))
    run("codesign", "--force", "--sign", args.identity, str(macos / "zapas-native-host"))
    run("codesign", "--force", "--sign", args.identity, str(app))
    run("codesign", "--verify", "--strict", str(app))
    print(app)
    print(f"CLI: {macos / 'zapas'}")

if __name__ == "__main__":
    main()
