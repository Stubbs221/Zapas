#!/usr/bin/env python3
"""Build and locally sign the standalone macOS Stage B app; no installation or login registration."""
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
    args = parser.parse_args()
    scratch = ROOT / ".local/release-build"
    run("swift", "build", "-c", "release", "--scratch-path", str(scratch))
    binaries = Path(subprocess.check_output(["swift", "build", "-c", "release", "--scratch-path", str(scratch), "--show-bin-path"], cwd=ROOT, env=BUILD_ENV, text=True).strip())
    app = ROOT / ".local/StageB/Zapas.app"
    if app.exists():
        # Only this script's fixed, ignored output is replaced; never an installed app.
        shutil.rmtree(app)
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    # Zapas/zapas would collide on the default case-insensitive macOS filesystem.
    for source, target in [("ZapasApp", "ZapasApp"), ("zapas", "zapas")]:
        shutil.copy2(binaries / source, macos / target)
    plist = {
        "CFBundleIdentifier": "com.stubbs221.Zapas",
        "CFBundleName": "Zapas", "CFBundleDisplayName": "Zapas",
        "CFBundleExecutable": "ZapasApp", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "CFBundleDevelopmentRegion": "ru", "CFBundleLocalizations": ["ru"],
    }
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(plist, file)
    (resources / "About.txt").write_text("Zapas 0.2.0 — локальная диагностика памяти. История только в памяти.\n", encoding="utf-8")
    run("codesign", "--force", "--sign", args.identity, str(macos / "zapas"))
    run("codesign", "--force", "--sign", args.identity, str(app))
    run("codesign", "--verify", "--strict", str(app))
    print(app)
    print(f"CLI: {macos / 'zapas'}")

if __name__ == "__main__":
    main()
