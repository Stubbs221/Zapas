#!/usr/bin/env python3
"""Prepare only ignored, isolated Chrome test data; never install into the working profile."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path(__file__).resolve().parents[1]
local = root / ".local"
local.mkdir(mode=0o700, exist_ok=True)
local.chmod(0o700)
profile = local / "chrome-profile"
profile.mkdir(mode=0o700, exist_ok=True)
runtime = local / "run"
runtime.mkdir(mode=0o700, exist_ok=True)
runtime.chmod(0o700)
socket = runtime / "broker.sock"
manifest = json.loads((root / "chrome-extension" / "manifest.json").read_text())
digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
extension_id = "".join(chr(ord("a") + int(char, 16)) for char in digest)
origin = f"chrome-extension://{extension_id}/"
binary_dir = Path(subprocess.check_output(
    ["swift", "build", "--scratch-path", str(local / "build"), "--show-bin-path"], cwd=root, text=True).strip().splitlines()[-1])
host = binary_dir / "zapas-native-host"
probe = binary_dir / "zapas-probe"
if not host.is_file() or not probe.is_file():
    raise SystemExit("Build first: swift build --scratch-path .local/build")
wrapper = local / "native-host"
wrapper.write_text("#!/bin/sh\n" +
    f"export ZAPAS_ALLOWED_ORIGIN={shlex.quote(origin)}\n" +
    f"export ZAPAS_SOCKET={shlex.quote(str(socket))}\n" +
    f"exec {shlex.quote(str(host))} \"$@\"\n")
wrapper.chmod(0o700)
hosts = profile / "NativeMessagingHosts"
hosts.mkdir(mode=0o700, exist_ok=True)
host_manifest = hosts / "com.zapas.stage_a.json"
host_manifest.write_text(json.dumps({"name": "com.zapas.stage_a", "description": "Zapas isolated stage A host",
    "path": str(wrapper), "type": "stdio", "allowed_origins": [origin]}, indent=2) + "\n")
host_manifest.chmod(0o600)
configuration = {"extensionID": extension_id, "origin": origin, "profile": str(profile), "socket": str(socket),
    "probe": str(probe), "host": str(host), "controlURL": origin + "control.html",
    "extensionDirectory": str(root / "chrome-extension"),
    "brokerCommand": [str(probe), "serve", "--socket", str(socket), "--origin", origin, "--seconds", "1800"],
    "chromeCommand": ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "--user-data-dir=" + str(profile), "--no-first-run", "--no-default-browser-check", "--disable-sync", "chrome://extensions/"]}
path = local / "chrome-test-config.json"
path.write_text(json.dumps(configuration, indent=2) + "\n")
path.chmod(0o600)
print(f"Prepared isolated profile. Extension ID: {extension_id}")
print("Local commands and paths: .local/chrome-test-config.json")
