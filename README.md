# AutoBrightness

<img src="artwork/autobrightness-128.png" width="80" alt="AutoBrightness icon">

A small native macOS menu bar app for the built-in display's **Automatically adjust brightness** setting (System Settings → Displays).

## Use

Open **AutoBrightness.app**. A sun appears in the menu bar:

- **Left-click:** turn automatic brightness on or off immediately.
- **Filled sun:** on. **Outline sun:** off. A faded outline means the setting can't be read or isn't available.
- **Hover:** rest the pointer on the icon for half a second and a small native Liquid Glass label (Apple's system font and text styles) shows the name, the current state and what a click does. It disappears when the pointer leaves, on click, or after eight seconds. It is drawn by a short-lived copy of the same executable (`--hover`) so the Liquid Glass memory stays out of the icon process; Reduce Transparency gives an opaque card instead.
- **Right-click** (or Control-click, or the VoiceOver "Show options" action): a frosted panel (its own short-lived process, so it never grows the icon process) opens under the icon with the **Automatic brightness** switch, a short explanation, **Displays Settings…** and **Quit**. Click outside, press Escape, or click the icon again to dismiss it. Space or Return operates the focused control, Tab moves between them.
- If a left-click can't change the setting, or the Mac has no ambient light sensor, the panel opens and says why. On an unsupported Mac there is no switch, only a button that opens Displays settings.

Every change is confirmed by reading the setting back from macOS before the icon or switch moves, and a second change is ignored while one is in flight. macOS does the ambient light sensing itself; the app does nothing in the background. It asks for no Accessibility, Screen Recording or administrator permission and makes no network requests. There is no helper process: the only other processes are short-lived hover-label and panel children, second launches of the same executable that exit when closed. It controls only this one setting for the built-in display — no keyboard backlight, True Tone, Night Shift, external displays, schedules, thresholds or brightness slider.

**Staying in sync.** macOS sends apps no change notification for this setting (System Settings itself re-reads it about twice a second while its Displays pane is open), so the icon re-reads it at the moments it could have changed: at launch, when the pointer reaches the icon, whenever another app becomes active, and **once a second only while System Settings is the frontmost app**. An open panel also re-reads every second. Nothing runs otherwise, and a click always flips the real current value. A change made in System Settings therefore shows on the icon within about a second.

The reverse is not fully possible: System Settings' own switch does not follow outside changes (from AutoBrightness or anything else) while its Displays pane stays open. Its warning text under the switch updates live, but the switch itself refreshes only when Settings is reopened or reactivated. That is System Settings' behavior, not something an app can change.

## Runs in the background, starts at login

AutoBrightness has no Dock icon or window; it just lives in the menu bar. **`./install.sh`** builds it, copies it to `/Applications` and opens it. The first time it runs from an Applications folder it registers itself as a login item with Apple's `SMAppService` (once, remembered in its preferences), so it starts every time you log in. macOS may show a "Login Item added" notice. To stop it, switch it off in System Settings → General → Login Items & Extensions; the app will not re-enable it. Runs from the build folder never register.

## Build and run

Needs Apple silicon, macOS 26.4 or newer and Apple's command-line developer tools. Built and verified on a MacBook Air (Mac17,4, Apple M5) running macOS 27.0.1.

```sh
./build.sh      # builds and ad-hoc signs AutoBrightness.app (icon is generated from drawing code)
./test.sh       # backend + UI checks against a fake backend; never touches the real setting
open AutoBrightness.app
./install.sh    # build + install to /Applications + start (registers the login item)
```

Diagnostics on the built executable:

```sh
./AutoBrightness.app/Contents/MacOS/AutoBrightness --diagnose   # print the setting; changes nothing
./AutoBrightness.app/Contents/MacOS/AutoBrightness --profile    # open the panel, reopen it five times; read-only
./AutoBrightness.app/Contents/MacOS/AutoBrightness --verify     # LIVE: really toggles the setting, then restores it
./AutoBrightness.app/Contents/MacOS/AutoBrightness --selftest   # LIVE: the icon process as shipped, via real click/hover/panel-child paths; restores
```

`--verify` (panel, keyboard, accessibility, clicks) and `--selftest` (the shipped icon process, the memory figure) identify themselves, is never run by `build.sh` or `test.sh`, snapshots the original value, and restores and re-reads it on normal completion, Quit, SIGINT, SIGTERM and SIGHUP (a `kill -9` cannot be intercepted). Measure through LaunchServices with
`open -n -W -a AutoBrightness.app --stdout out.txt --args --verify`.
CPU of an idle normal instance: `xcrun clang -Os research/cpu-measure.c -o /tmp/cpu && /tmp/cpu PID 20`.

## Private API risk

Apple documents the setting only as a checkbox; there is no public API. The app calls three private functions from `DisplayServices.framework` (`DisplayServicesHasAmbientLightCompensation`, `…AmbientLightCompensationEnabled`, `…EnableAmbientLightCompensation`), loaded with `dlopen`/`dlsym`. Their arm64 signatures were read from the disassembly, not guessed — see `research/Backend.md`. The app refuses to run (unsupported state) if the framework or a symbol is missing, no built-in display or ambient light sensor exists, the getter fails or returns a non-boolean/unwritten byte, or a write isn't confirmed by readback. A future macOS update can still remove or change these functions, and one that keeps the signatures but changes their meaning could not be detected. The panel's blur likewise uses a private SkyLight call, with a native `NSVisualEffectView` fallback. It can't be distributed through the Mac App Store.

## Resource use

**The 8.00 MB footprint target is not met, and cannot be on this machine.** The icon process (the one that is always running) was cut from a 10.6 MB peak to **8.68 MB after a full interaction** (menu bar clicks in both directions, hover label, three panel open/close cycles; lifetime peak 8.85–9.03 MB, `--selftest`), by moving the panel and hover label into short-lived child processes. But a bare AppKit app that only creates one `NSStatusItem` measures 8.1–8.9 MB at the same moments (8.65 MB footprint / 8.91 MB peak in an interleaved comparison against this app's 8.43 / 8.77): the status item and the first window machinery are a floor that no setting I found moves. `research/Memory.md` has every experiment; `Verification.log` has the numbers. While the panel or hover label is open, its child process adds its own ~14 MB (see Memory.md); it exits when closed.

Idle CPU over 20 s: about 0.003% of one core (0.6 ms), a few non-periodic wakeups. No timers, no polling.

## Files

`src/auto.h` backend (load, read, write with readback) · `src/main.m` app, status item, panel, verification modes · `src/tests.m`, `src/ui-tests.m`, `src/fake.h` checks · `research/` backend and memory notes, probes · `artwork/draw-icon.m` icon. MIT licensed (`LICENSE`).
