# Memory investigation

Metric: `TASK_VM_INFO.phys_footprint` (decimal MB) and its kernel lifetime peak, normal LaunchServices launch (`open -n -a`), macOS 27.0.1, MacBook Air (Mac17,4, M5). Target: peak < 8.00 MB. **Result: not met.**

## The floor is above the budget

`research/`-style probe (a 20-line AppKit accessory app, `LSUIElement`, nothing else), footprint / lifetime peak after 3 s:

| Variant | Footprint | Peak |
|---|---|---|
| no status item, default allocator | 8.127 | 8.160 |
| no status item, 4 allocator flags | 5.489 | 5.522 |
| one `NSStatusItem` (text title), default allocator | 12.633 | 12.682 |
| one `NSStatusItem` (text title), 4 allocator flags | 8.078 | 8.422 |
| `NSStatusItem` with template image, 4 flags | 8.635 | 8.635 |
| + `malloc_zone_pressure_relief` at 1.5 s | 8.373 / 8.570 | 8.406 / 8.570 |

An app with one status item and nothing else is already at about 8.1 MB footprint and 8.4 MB peak with the best settings found; the status item alone costs ~2.6 MB. The brief requires an `NSStatusItem`, so < 8.00 MB is not reachable on this OS. (`vmmap` shows the extra memory is Malloc Small, `__DATA_DIRTY` and AppKit/SkyLight state created by the status item, not anything the app allocates itself.)

## Allocator A/B (the brief asks for measurement before adding any setting)

Read-only `--profile` (open panel, five reopenings), environment set with `open --env`, lifetime peak of the whole run (panel-resident build, before the status-icon redesign):

| Environment | Idle | Peak |
|---|---|---|
| none | 12.485 | 17.499 |
| `MallocSpaceEfficient=1` | 9.258 | 11.568 |
| `MallocMaxMagazines=1` only | 10.306 | 14.943 |
| `MallocMediumZone=0` only | 12.682 | 18.466 |
| all four (`SpaceEfficient`, `MaxMagazines=1`, `MediumZone=0`, `NanoZone=0`) | 8.439 | 10.945 |

The four process-local flags lowered the real peak by 6.5 MB, so they ship in `Info.plist` `LSEnvironment` (no global setting changes). `malloc_zone_pressure_relief` after the panel is freed was also A/B tested: post-interaction footprint 9.44 → 8.60 MB in that pair of runs, so it stays; it cannot lower the lifetime peak.

## What the app itself does

- Single `NSStatusItem`, single process, no timers; backend work runs on one serial dispatch queue.
- The panel (window, one IOSurface at backing scale, SkyLight blur) is created on right-click and **freed when it closes**; an ordinary left-click toggle never builds it.
- All controls paint into the panel's one surface; they have no layers' backing stores of their own. No `NSVisualEffectView` unless the private blur is unavailable (an `NSVisualEffectView` hierarchy cost ~88 MB of graphics memory in ChargeCap's investigation).
- Panel open adds about 1.2 MB over idle; repeated reopen adds ~0.1 MB each.

Not tried because the brief forbids it: a second short-lived process for the panel (as ScrollToggle does). It would not help the launch peak, which is already 8.14 MB.

## Hover label (Liquid Glass)

`NSGlassEffectView` shown inside the icon process added about 5.5 MB (with the allocator flags) and did not give it back after the label closed, even with `malloc_zone_pressure_relief`. The label is therefore drawn by a short-lived second launch of the executable (`--hover`, no lock, no status item), as ScrollToggle does. The child measures about 14 MB while it exists and exits by itself after 8 s or when the icon process terminates it; the icon process footprint is unchanged by showing it (9.094 MB before, 9.110 MB after in `--verify`). Hover bookkeeping and the tracking area cost the icon process roughly 0.3 MB at launch (installed plain launch 8.18–8.39 MB vs 7.85 MB before).

## Round 2: finding the floor (status item alone)

Interleaved A/B on a 20-line AppKit accessory app, same allocator flags, n = 3–6 per arm (footprint MB; the whole system drifts by ±0.3 MB over minutes, so only interleaved comparisons count):

| Variant | Footprint |
|---|---|
| no window, no status item | 5.30 |
| one borderless window (no status item) | 7.47 |
| one `NSStatusItem` with template image | 8.67 |
| + `registerDefaults` (ApplePersistenceIgnoreState, NSQuitAlwaysKeepsWindows, …) | 8.65 vs 8.59 base — no effect |
| + `OS_ACTIVITY_MODE=disable` | 8.87 vs 8.78 — no effect |
| + AppKit text/autofill/spelling defaults via argv | 8.67 vs 8.62 — no effect |
| + `malloc_zone_pressure_relief` 1.5 s after launch | 8.70 vs 8.63 — no effect |
| + loading DisplayServices and reading the setting | 8.68 vs 8.81 — no measurable cost |
| + autosaveName / accessibility label / tracking area | within noise |
| title text instead of image | not lower (8.9 vs 8.6) |

The first window costs ~2.2 MB (Metal/AGX driver and CoreAnimation context load on first use) and the status item another ~1.2 MB; `malloc_history` charges 0.7 MB of heap to `NSApplication` creation, 1.2 MB to creating the status item and 1.4 MB to the run loop start. AppKit on this macOS maps ~930 images at launch (AppIntents, CoreSpotlight, CloudKit, GenerativeModels, …) with delayed initializers, and a batch of Siri/Spotlight frameworks is touched after the first window. None of that is controllable from the app.

The shipped app measured 8.43 / 8.77 (footprint / peak) against 8.65 / 8.91 for the equivalent minimal app in the same interleaved run, i.e. at or slightly below the floor.

## Round 2: what did help

Moving the panel (window, 684 KB drawing surface, SkyLight blur) out of the icon process into a `--panel` child. Icon process after a full interaction (`--selftest`, normal LaunchServices launch): footprint 8.668–8.684 MB, lifetime peak 8.848–9.028 MB, versus 9.4 MB / 10.5–10.6 MB when the panel was built in-process (`--verify`). The panel child is ~14 MB while open and exits on close; total system memory while the panel is open is therefore higher, not lower — only the always-running process shrank. Quitting from the panel exits the child with status 3, which the icon process turns into a normal quit.
