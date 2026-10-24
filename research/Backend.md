# Backend research: "Automatically adjust brightness"

Investigated on **macOS 27.0.1 (26A434), MacBook Air M5 (Mac17,4), arm64**, built-in "Liquid Retina Display" (CGDirectDisplayID 1).

## Result

No public API exists. A librarian search of Apple documentation, Apple Developer Forums and public GitHub found only the GUI checkbox in System Settings → Displays and one third-party JXA script that calls the same private functions. The setting is reachable through three private **DisplayServices** C functions, which the app loads with `dlopen`/`dlsym` from
`/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`. They were disassembled with `lldb` (`research/dis.lldb`) rather than guessed, and observed in use with `research/probe-live.c`.

| Symbol | Signature (arm64) | Behavior seen in disassembly |
|---|---|---|
| `DisplayServicesHasAmbientLightCompensation` | `uint8_t (uint32_t display)` | asks the DisplayServices client for property `DisplayServicesHasAmbientLightCompensation`; returns its boolean, 0 if the query fails |
| `DisplayServicesAmbientLightCompensationEnabled` | `int (uint32_t display, bool *out)` | reads property `DisplayServicesAmbientLightCompensationEnabled`; on success stores one byte in `*out` and returns `0`; otherwise returns `0xe00002bc` (`kIOReturnError`) without writing `*out` |
| `DisplayServicesEnableAmbientLightCompensation` | `int (uint32_t display, bool enable)` | sets that same property with an `NSNumber` bool; returns `0` on success, `0xe00002bc` on failure |

`DisplayServicesCanChangeBrightness`, `…GetBrightness` and the ambient-light-compensation *notification* registration also exist, but are not used (see below). `DisplayServicesAutoBrightnessEnabled`-style names do **not** exist.

## State storage and readback

The functions go through the private DisplayServices client (`getDSClientQueued`) to the system brightness service; the app holds no copy of the value. The exact on-disk location was not identified (`com.apple.CoreBrightness` is not readable as a user default) and is not needed.

Readback is the getter called again after a write. It was cross-checked three independent ways on the build machine, always restoring the original value:

1. same process: `set(0)` → get=0, `set(1)` → get=1;
2. **separate process**: process A sets off, process B (fresh `dlopen`) reads 0, then A restores;
3. **System Settings' own data**: `system_profiler SPDisplaysDataType` reports `Automatically Adjust Brightness: No` at value 0 and `Yes` at value 1.

## Supported scope

Verified on exactly the machine above. The app refuses (shows an unsupported state, never an enabled switch) when: not arm64, the framework or any symbol is missing, no built-in display is active, `Has…` is false (no ambient light sensor), the getter fails, or it leaves its out byte unwritten / writes anything but 0 or 1 (the byte is pre-set to `0xAA` to detect an ABI mismatch). A write counts only if the setter returns 0 **and** an independent read returns the requested value. Other macOS versions or Macs are untested; the guards turn a changed ABI into an error rather than a wrong answer, but an update that keeps the same signatures and changes their meaning could not be detected.

## Notifications

`DisplayServicesRegisterForAmbientLightCompensationNotifications(a, b, c)` forwards to `DisplayServicesAddNotification` with the name `DisplayServicesAmbientBrightness`. That name is the **ambient light level**, not the on/off setting, so it would wake the app on every lux change and would not report a change made in System Settings. Not used. The app refreshes on launch, when the panel opens, and on every menu bar click (which reads the real value before flipping it). Consequence: if the setting is changed elsewhere, the icon can be stale until the next click or panel open; a click still flips the *real* value.

## Research safety

Every probe saved the original value and restored it (`restore` on exit, SIGINT and SIGTERM in `probe-live.c`; a shell `trap` for the cross-process test). The original value (on) was read back after each probe.
