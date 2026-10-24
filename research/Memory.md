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
