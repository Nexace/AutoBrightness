#define main ProductMain
#import "main.m"
#undef main
#include <assert.h>
#include "fake.h"

static void Pump(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(done());
}
static void Settle(AutoApp *app) { Pump(^BOOL{ return !app.busy; }); }
static NSEvent *Key(NSInteger window, unsigned short code, NSString *characters) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
}
static uint8_t AlphaAt(NSView *view, CGFloat x, CGFloat y) {
    [view updateLayer];
    IOSurfaceRef surface = (__bridge IOSurfaceRef)((AutoView *)view).rasterSurface;
    assert(surface && IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess);
    CGFloat scale = view.window.backingScaleFactor ?: 2;
    uint8_t alpha = ((uint8_t *)IOSurfaceGetBaseAddress(surface))[(size_t)(y * scale) * IOSurfaceGetBytesPerRow(surface) + (size_t)(x * scale) * 4 + 3];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return alpha;
}

static NSInteger spawns;
static NSArray *spawned;
static NSTask *StubSpawn(NSArray<NSString *> *arguments, void (^finished)(NSTask *)) { // a harmless long-running stand-in for a child
    spawns++; spawned = arguments;
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"]; task.arguments = @[@"30"];
    if (finished) task.terminationHandler = finished;
    return [task launchAndReturnError:nil] ? task : nil;
}

int main(void) { @autoreleasepool {
    [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
    FindDisplay = FakeDisplay;
    ResetFake();
    AutoApp *app = [AutoApp new];
    app.retainPanel = YES; app.inProcessPanel = YES;
    [app makePanel];
    AutoView *view = app.view;
    PanelControl *toggle = view.toggle;
    assert(StatusIcon(SunFilled,1).isTemplate && StatusIcon(SunRing,.45).isTemplate);

    // Both states are read from the system and shown only after the read completes.
    assert(view.state == AutoChecking && !toggle.enabled);
    FakeByte = 1; [app refresh]; Settle(app);
    assert(view.state == AutoOn && toggle.on && toggle.enabled && !view.message && !view.openPill.isHidden == NO);
    FakeByte = 0; [app refresh]; Settle(app);
    assert(view.state == AutoOff && !toggle.on && toggle.enabled);

    // Accessibility: role, label, value, help, and the press action.
    assert([toggle.accessibilityRole isEqual:NSAccessibilityCheckBoxRole] && [toggle.accessibilitySubrole isEqual:NSAccessibilitySwitchSubrole]);
    assert([toggle.accessibilityLabel isEqual:@"Automatic brightness"] && [toggle.accessibilityValue isEqual:@0] && toggle.accessibilityHelp.length);
    assert([toggle.accessibilityValueDescription isEqual:@"Off"] && view.settings.accessibilityLabel.length && view.quit.accessibilityLabel.length);

    // A user change applies once, blocks duplicates, and shows the new value only after readback.
    assert([toggle accessibilityPerformPress] && app.busy && !toggle.enabled);
    assert(![toggle accessibilityPerformPress] && app.writes == 1);
    assert(!toggle.on); // not yet confirmed
    Settle(app);
    assert(FakeSets == 1 && toggle.on && view.state == AutoOn && !view.message && [toggle.accessibilityValue isEqual:@1]);

    // Keyboard: Space and Return press the focused control; other keys do not.
    [toggle keyDown:Key(0, 49, @" ")]; Settle(app);
    assert(!toggle.on && FakeSets == 2);
    [toggle keyDown:Key(0, 0, @"a")]; assert(!app.busy && FakeSets == 2);
    [toggle keyDown:Key(0, 36, @"\r")]; Settle(app);
    assert(toggle.on && FakeSets == 3);
    assert(toggle.nextKeyView == view.settings && view.settings.nextKeyView == view.openPill && view.quit.nextKeyView == toggle);

    // Rejected write: compact error, and the switch shows what macOS really has.
    FakeSetResult = (int)0xe00002bc; [toggle press]; Settle(app);
    assert(view.message && toggle.on && view.state == AutoOn);
    FakeSetResult = 0; FakeIgnoreSet = YES; [toggle press]; Settle(app);
    assert(view.message && toggle.on && FakeByte == 1); // success without matching readback
    FakeIgnoreSet = NO; [toggle press]; Settle(app);
    assert(!view.message && !toggle.on);

    // Unreadable setting: disabled switch with an error, not an enabled one that cannot work.
    FakeGetResult = (int)0xe00002bc; [app refresh]; Settle(app);
    assert(view.state == AutoUnreadable && view.message && !toggle.enabled && !toggle.press);
    FakeGetResult = 0;

    // Unsupported Mac: no switch, a button to open Displays settings.
    FakeHas = 0; [app refresh]; Settle(app);
    assert(view.state == AutoUnsupported && toggle.isHidden && view.settings.isHidden && !view.openPill.isHidden && view.message);
    assert([view.openPill.accessibilityRole isEqual:NSAccessibilityButtonRole] && FakeSets == 6);
    FakeHas = 1;
    // Missing system control: also unsupported, via the real loader pointed at nothing.
    Backend = (AutoBackend){0}; BackendPath = "/nonexistent/DisplayServices";
    [app refresh]; Settle(app);
    assert(view.state == AutoUnsupported && toggle.isHidden);
    BackendPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";
    ResetFake(); [app refresh]; Settle(app);
    assert(view.state == AutoOn && !toggle.isHidden && view.openPill.isHidden);

    [app closePanel:nil]; // earlier failures opened it, as a failed menu bar click does
    // Menu bar click: toggles directly with no panel; the icon follows the confirmed value.
    FakeByte = 1; [app refresh]; Settle(app);
    assert(app.iconState == AutoOn && !app.panel.visible);
    NSInteger sets = FakeSets;
    [app click:NO]; assert(app.busy); Settle(app);
    assert(FakeSets == sets + 1 && FakeByte == 0 && app.iconState == AutoOff && !app.panel.visible && !view.toggle.on);
    [app click:NO]; Settle(app);
    assert(FakeByte == 1 && app.iconState == AutoOn && !app.panel.visible);
    // The click re-reads the real setting, so an outside change is never overridden blindly.
    FakeByte = 0; [app click:NO]; Settle(app); assert(FakeByte == 1 && app.iconState == AutoOn);
    // A failed direct click opens the panel to explain.
    FakeSetResult = (int)0xe00002bc; [app click:NO]; Settle(app);
    assert(app.panel.visible && view.message && app.iconState == AutoOn && FakeByte == 1);
    [app click:NO]; assert(!app.panel.visible); // clicking the icon again dismisses it
    FakeSetResult = 0;
    // Right/Control click opens the panel; so does an unavailable setting.
    [app click:YES]; assert(app.panel.visible); Settle(app); [app click:NO]; assert(!app.panel.visible);
    FakeHas = 0; [app refresh]; Settle(app); [app click:NO]; assert(app.panel.visible && view.state == AutoUnsupported);
    [app click:NO]; FakeHas = 1; [app refresh]; Settle(app);
    assert([app showOptions:nil] && app.panel.visible); Settle(app); [app closePanel:nil];

    // Hover label: lines, spawn/stop of the child, and the window it draws (glass or opaque card).
    assert([app.hoverLines[1] isEqual:@"Automatic brightness: On"] && [app.hoverLines[2] hasPrefix:@"Click to turn off"]);
    app.iconState = AutoOff; assert([app.hoverLines[2] hasPrefix:@"Click to turn on"]);
    app.iconState = AutoUnsupported; assert([app.hoverLines[1] hasSuffix:@"unavailable"] && [app.hoverLines[2] isEqual:@"Right-click for options"]);
    app.iconState = AutoOn;
    ChildSpawner = StubSpawn;
    [app showHover]; assert(spawns == 1 && app.hoverTask.isRunning && [spawned[0] isEqual:@"--hover"] && spawned.count == 8 && [spawned[5] isEqual:@"AutoBrightness"]);
    NSTask *task = app.hoverTask;
    [app showHover]; assert(spawns == 1); // one label at a time
    [app hideHover]; assert(!app.hoverTask); Pump(^BOOL{ return !task.isRunning; });
    [app mouseEntered:nil]; assert(spawns == 1); // appears only after the delay
    Pump(^BOOL{ return spawns == 2; });
    [app mouseExited:nil]; assert(!app.hoverTask);
    [app mouseEntered:nil]; [app mouseExited:nil];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.7]]; assert(spawns == 2); // left before the delay
    [app showHover]; [app statusClicked:nil]; assert(!app.hoverTask); Settle(app); // a click dismisses it, then toggles
    [app click:NO]; Settle(app); assert(app.iconState == AutoOn && FakeByte == 1); // toggle back
    [app showHover]; [app click:YES]; assert(!app.hoverTask && app.panel.visible); [app closePanel:nil];
    [app showHover]; [app openPanel:NO]; assert(!app.hoverTask); [app closePanel:nil];
    ChildSpawner = SpawnChild;
    ReduceTransparencyOverride = 0;
    NSPanel *label = [app makeHoverWindow:app.hoverLines midX:500 top:900 minX:0 maxX:1000];
    assert(label.visible && [label.contentView isKindOfClass:NSGlassEffectView.class]); // native Liquid Glass
    NSView *labels = ((NSGlassEffectView *)label.contentView).contentView;
    assert(labels.subviews.count == 3 && [[(NSTextField *)labels.subviews[0] stringValue] isEqual:@"AutoBrightness"]);
    assert([[(NSTextField *)labels.subviews[0] font] isEqual:[NSFont preferredFontForTextStyle:NSFontTextStyleHeadline options:@{}]]); // Apple text style
    assert(fabs(NSMidX(label.frame) - 500) < 1 && NSMaxY(label.frame) < 900);
    [label orderOut:nil];
    ReduceTransparencyOverride = 1; // opaque card instead of glass
    label = [app makeHoverWindow:app.hoverLines midX:500 top:900 minX:0 maxX:1000];
    assert(![label.contentView isKindOfClass:NSGlassEffectView.class] && label.contentView.subviews.count == 3); [label orderOut:nil];
    label = [app makeHoverWindow:app.hoverLines midX:5 top:900 minX:0 maxX:1000]; // clamped to the screen edge
    assert(NSMinX(label.frame) >= 8); [label orderOut:nil];
    ReduceTransparencyOverride = -1;

    // Production path: the icon process never builds the panel; it spawns a child and reacts to its exit.
    app.inProcessPanel = NO; spawns = 0; ChildSpawner = StubSpawn;
    [app click:YES]; assert(spawns == 1 && app.panelOpen && !app.panel.visible && [spawned[0] isEqual:@"--panel"] && spawned.count == 9);
    NSTask *panelTask = app.panelTask;
    [app showHover]; assert(spawns == 1); // no label while the panel is open
    [app click:NO]; // clicking the icon again closes the child instead of toggling
    Pump(^BOOL{ return !panelTask.isRunning && !app.panelTask; }); Settle(app); assert(FakeByte == 1);
    [app click:YES]; assert(spawns == 2); [app closePanel:nil]; Pump(^BOOL{ return !app.panelTask; });
    Settle(app); // the exit handler refreshes the icon
    FakeSetResult = (int)0xe00002bc; [app click:NO]; Settle(app); // a failed click explains itself in the panel
    assert(spawns == 3 && spawned.count == 10 && [spawned.lastObject length] > 0 && [spawned.lastObject isEqual:app.lastMessage]);
    [app closePanel:nil]; Pump(^BOOL{ return !app.panelTask; }); FakeSetResult = 0;
    NSTask *exited = [NSTask new]; exited.executableURL = [NSURL fileURLWithPath:@"/bin/sh"]; exited.arguments = @[@"-c", @"exit 3"];
    [exited launchAndReturnError:nil]; [exited waitUntilExit]; assert(PanelExitMeansQuit(exited));
    exited = [NSTask new]; exited.executableURL = [NSURL fileURLWithPath:@"/bin/sh"]; exited.arguments = @[@"-c", @"exit 0"];
    [exited launchAndReturnError:nil]; [exited waitUntilExit]; assert(!PanelExitMeansQuit(exited));
    ChildSpawner = SpawnChild; app.inProcessPanel = YES;
    // The child side: placed under the icon it was told about, shows the failure it was handed, ignores icon clicks.
    AutoApp *child = [AutoApp new]; child.retainPanel = YES;
    child.panelArguments = @[@"700", @"900", @"0", @"1440", @"690", @"878", @"22", @"22", @"Test failure"];
    [child runPanelChild:child.panelArguments]; assert(child.panel.visible && child.hasForcedAnchor);
    assert(fabs(NSMidX(child.panel.frame) - 701) < 1 && NSMaxY(child.panel.frame) < 900 && child.item == nil);
    Settle(child); assert([child.view.message isEqual:@"Test failure"] && child.view.state == AutoOn);
    child.panelArguments = nil; [child closePanel:nil]; assert(!child.panel.visible);

    // Staying in sync: a quiet re-read follows outside changes without dimming, and keeps a failure message.
    FakeByte = 1; [app refresh]; Settle(app); assert(app.iconState == AutoOn);
    FakeByte = 0; [app refreshQuietly:YES]; assert(app.busy && view.toggle.enabled); Settle(app); // no dimming while reading
    assert(app.iconState == AutoOff && !view.toggle.on && view.state == AutoOff);
    FakeByte = 1; [app refreshQuietly:YES]; Settle(app); assert(app.iconState == AutoOn && view.toggle.on);
    FakeSetResult = (int)0xe00002bc; [app change:NO to:NO]; Settle(app); assert(view.message);
    [app closePanel:nil]; FakeSetResult = 0;
    [app refreshQuietly:YES]; Settle(app); assert(view.message && app.iconState == AutoOn); // failure explanation survives a quiet read
    [app change:NO to:NO]; Settle(app); assert(!view.message && app.iconState == AutoOff); // the next change clears it
    [app change:NO to:YES]; Settle(app); assert(app.iconState == AutoOn);
    FakeByte = 0; [app mouseEntered:nil]; Pump(^BOOL{ return app.iconState == AutoOff; }); [app mouseExited:nil]; // hover re-reads
    FakeByte = 1; [app refresh]; Settle(app);

    // Panel placement and dismissal: Escape, outside click, and the status item toggle.
    [app togglePanel:nil]; assert(app.panel.visible);
    NSRect frame = app.panel.frame, visible = app.panel.screen.visibleFrame;
    assert(NSMinX(frame) >= NSMinX(visible) && NSMaxX(frame) <= NSMaxX(visible) && NSMaxY(frame) <= NSMaxY(visible));
    Settle(app);
    [NSApp sendEvent:Key(app.panel.windowNumber, 53, @"\e")]; assert(!app.panel.visible);
    [app togglePanel:nil]; assert(app.panel.visible);
    NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [other orderBack:nil]; // stands in for any window outside the panel
    [NSApp sendEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(5, 5) modifierFlags:0 timestamp:0 windowNumber:other.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1]];
    assert(!app.panel.visible);
    [app togglePanel:nil]; [app togglePanel:nil]; assert(!app.panel.visible); // second click closes
    Settle(app);

    // Rendering: transparent corners, translucent body, opaque with Reduce Transparency.
    ReduceTransparencyOverride = 0; assert(AlphaAt(view, 1, 1) == 0);
    uint8_t body = AlphaAt(view, 130, 100); assert(body > 150 && body < 200);
    ReduceTransparencyOverride = 1; assert(AlphaAt(view, 130, 100) == 255);
    ReduceTransparencyOverride = -1;
    // In normal operation the panel is freed on close and rebuilt, with current state, on reopen.
    app.retainPanel = NO; [app togglePanel:nil]; Settle(app); [app closePanel:nil];
    Pump(^BOOL{ return app.panel == nil && app.view == nil; });
    [app click:YES]; assert(app.panel.visible && app.view.state == AutoOn && app.view.toggle.on); Settle(app); [app closePanel:nil];
    Pump(^BOOL{ return app.panel == nil; });
    FakeByte = 0; [app click:NO]; Settle(app); // a direct click never needs the panel
    assert(app.panel == nil && app.iconState == AutoOn && FakeByte == 1); // read the real 0, wrote 1
    puts("PASS: both states, press/keyboard/accessibility, busy guard, errors, unsupported, dismissal, and rendering.");
    return 0;
} }
