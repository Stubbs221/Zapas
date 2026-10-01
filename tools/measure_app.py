#!/usr/bin/env python3
"""Read-only libproc cost measurements for an explicitly selected Zapas PID; raw output stays in .local."""
import argparse
import ctypes
import datetime
import json
from pathlib import Path
import time

class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(key, ctypes.c_uint64) for key in (
        "user_time", "system_time", "idle_wakeups", "interrupt_wakeups", "pageins", "wired", "rss", "footprint", "start", "exit")]

class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

def timebase_ratio():
    # rusage CPU counters are Mach absolute ticks (XNU task_power_info_locked), not ns on arm64.
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    info = Timebase()
    if system.mach_timebase_info(ctypes.byref(info)) != 0 or info.denom == 0:
        raise RuntimeError("mach_timebase_info unavailable")
    return info

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.seconds <= 600 or ".local" not in args.output.resolve().parts:
        parser.error("Use a positive PID, 1...600 seconds and an output inside .local")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    path = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(args.pid, path, len(path)) <= 0 or not path.value.decode().endswith("/Zapas.app/Contents/MacOS/ZapasApp"):
        parser.error("Selected PID is not a packaged Zapas executable")
    samples = []
    timebase = timebase_ratio()
    start = time.monotonic()
    while True:
        usage = Usage()
        if lib.proc_pid_rusage(args.pid, 0, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), "proc_pid_rusage")
        if samples and (usage.start != samples[0]["start"] or bytes(usage.uuid).hex() != samples[0]["uuid"]):
            raise RuntimeError("Process identity changed; measurement discarded")
        samples.append({"at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "elapsedSeconds": time.monotonic() - start,
                        "cpuAbsoluteTicks": usage.user_time + usage.system_time, "footprintBytes": usage.footprint, "rssBytes": usage.rss,
                        "start": usage.start, "uuid": bytes(usage.uuid).hex(), "idleWakeups": usage.idle_wakeups})
        elapsed = samples[-1]["elapsedSeconds"]
        if elapsed >= args.seconds:
            break
        time.sleep(min(5, args.seconds - elapsed))
    elapsed = samples[-1]["elapsedSeconds"] - samples[0]["elapsedSeconds"]
    cpu_seconds = (samples[-1]["cpuAbsoluteTicks"] - samples[0]["cpuAbsoluteTicks"]) * timebase.numer / timebase.denom / 1e9
    result = {"source": "proc_pid_rusage.RUSAGE_INFO_V0", "pid": args.pid, "durationSeconds": elapsed,
              "cpuSeconds": cpu_seconds, "cpuPercentOfOneCore": 100 * cpu_seconds / elapsed,
              "machTimebase": {"numer": timebase.numer, "denom": timebase.denom},
              "minimumFootprintBytes": min(s["footprintBytes"] for s in samples),
              "maximumFootprintBytes": max(s["footprintBytes"] for s in samples), "samples": samples}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k not in ("samples", "pid")}, indent=2))

if __name__ == "__main__":
    main()
