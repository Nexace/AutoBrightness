#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>

// Private DisplayServices ABI, disassembled on macOS 27.0.1 arm64 (see research/Backend.md).
// Getter/setter return IOReturn (0 = success); has() returns the setting's availability as a byte.
typedef struct {
    uint8_t (*has)(uint32_t display);
    int (*get)(uint32_t display, bool *enabled);
    int (*set)(uint32_t display, bool enabled);
} AutoBackend;

// Test code replaces this; production resolves the real symbols once.
static AutoBackend Backend;

// Loads and validates the symbols. Returns nil on success, or why auto brightness is unsupported.
static NSString *LoadBackend(AutoBackend *backend, const char *path) {
#if !defined(__arm64__)
    (void)backend;(void)path;return @"Automatic brightness control is only verified on Apple silicon Macs.";
#else
    void *library = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!library) return @"macOS doesn’t provide display brightness controls here.";
    backend->has = dlsym(library, "DisplayServicesHasAmbientLightCompensation");
    backend->get = dlsym(library, "DisplayServicesAmbientLightCompensationEnabled");
    backend->set = dlsym(library, "DisplayServicesEnableAmbientLightCompensation");
    if (!backend->has || !backend->get || !backend->set) return @"This version of macOS has no automatic brightness control for apps.";
    return nil;
#endif
}

static const char *BackendPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";
static NSString *LoadSystemBackend(void) {
    if (Backend.has && Backend.get && Backend.set) return nil; // already resolved (or injected by tests)
    return LoadBackend(&Backend, BackendPath);
}

// The setting belongs to the built-in display only. Returns 0 when there isn't one.
static CGDirectDisplayID BuiltInDisplay(void) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < count; i++) if (CGDisplayIsBuiltin(displays[i])) return displays[i];
    return 0;
}

// A getter that fails to write its out byte, writes anything but 0/1, or writes more than a byte is an ABI mismatch.
// `unsupported` (optional) distinguishes "this Mac can't do it" from a failed read.
static NSString *ReadAuto(CGDirectDisplayID display, BOOL *enabled, BOOL *unsupported) {
    if (unsupported) *unsupported = YES;
    if (!display) return @"This Mac has no built-in display.";
    if (!Backend.has || !Backend.get) return @"Automatic brightness isn’t available on this version of macOS.";
    if (!Backend.has(display)) return @"This Mac’s built-in display has no ambient light sensor.";
    if (unsupported) *unsupported = NO;
    // A wider-than-a-byte write would also show up as a changed guard byte.
    uint8_t buffer[8];
    memset(buffer, 0xAA, sizeof buffer);
    int result = Backend.get(display, (bool *)buffer);
    if (result != 0) return [NSString stringWithFormat:@"macOS couldn’t read the setting (0x%x).", (unsigned)result];
    for (int i = 1; i < 8; i++) if (buffer[i] != 0xAA) return @"macOS returned an unrecognized automatic brightness state.";
    if (buffer[0] > 1) return @"macOS returned an unrecognized automatic brightness state.";
    *enabled = buffer[0] == 1;
    return nil;
}

// Success needs the setter to accept the value and an independent read to agree with it.
static NSString *WriteAuto(CGDirectDisplayID display, BOOL enabled) {
    BOOL current = NO;
    NSString *issue = ReadAuto(display, &current, NULL);
    if (issue) return issue;
    if (!Backend.set) return @"Automatic brightness isn’t available on this version of macOS.";
    int result = Backend.set(display, enabled);
    if (result != 0) return [NSString stringWithFormat:@"macOS didn’t accept the change (0x%x).", (unsigned)result];
    BOOL actual = NO;
    issue = ReadAuto(display, &actual, NULL);
    if (issue) return issue;
    return actual == enabled ? nil : @"macOS didn’t confirm the change. Check Displays settings.";
}
