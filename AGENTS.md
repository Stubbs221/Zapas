# Project instructions

## Simulator isolation

- Never assume that a simulator in the `Booted` state is available; it can be in use by another project.
- Before any build, test, install, launch, screenshot, or log collection on a simulator, inspect the available devices and select one that is explicitly assigned to the current project. If there is no assigned device, create or request a dedicated one instead of reusing a generic device.
- Do not modify, launch on, terminate, reset, erase, boot, or shut down a simulator associated with another project unless the user explicitly names that device and authorizes the action.
- Keep no more than eight CoreSimulator devices on this Mac across all projects and runtimes, counting both `Booted` and `Shutdown` devices. Before creating a device, inspect the full inventory. If eight devices already exist, obtain authorization to remove specifically named devices before creating another; never reuse or remove another project's device to meet this limit.
- Do not claim that an app has launched visibly based only on a CLI process ID. Confirm it in the matching Xcode Simulator or Device Hub window, and state clearly if that UI confirmation is unavailable.

## Jira browser preference

- When authorized to use browser UI for Jira, always use the user's existing Safari session. Never open Jira in Chrome, an isolated agent browser, or the in-app browser; the user is already signed in through Safari.
- This preference does not override project source-routing or read-only rules; obtain any required authorization to write or use browser UI separately.

## Zapas stage A

- Read `docs/StageA.md` and the latest `docs/StageAReport.md` before changing stage A prototypes.
- Swift 6, macOS 14 minimum. Shared core has no default main-actor isolation. New unit tests use Swift Testing.
- Keep original references, real measurements, browser data and simulator assignments in ignored `.local/`.
- The imported shell script is reference material, not an executable dependency or authorization to terminate processes.
- The only stage A action is explicitly selected discard of extension-created test tabs in the isolated Chrome profile. No general kill, simulator shutdown, browser restart or Charles control command.
- Preserve unavailable metrics as structured errors, never substitute zero. Never sum RSS and footprint or describe summed footprint as unique physical RAM.
- Commit subjects and bodies are in Russian; preserve technical identifiers.
