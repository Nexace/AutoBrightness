#import "auto.h"
#include <assert.h>
#include "fake.h"

int main(void) { @autoreleasepool {
    BOOL value = NO, unsupported = NO;
    // Unavailable framework or symbols: unsupported, never a call through a null pointer.
    AutoBackend loaded = {0};
    assert(LoadBackend(&loaded, "/nonexistent/DisplayServices") != nil);
    assert(LoadBackend(&loaded, "/usr/lib/libSystem.B.dylib") != nil); // loads, lacks the symbols
    Backend = (AutoBackend){0};
    assert(ReadAuto(1, &value, &unsupported) && unsupported);
    assert(WriteAuto(1, YES) != nil);
    ResetFake();
    assert(LoadSystemBackend() == nil);

    // Healthy reads in both states.
    FakeByte = 1; assert(!ReadAuto(1, &value, &unsupported) && value && !unsupported);
    FakeByte = 0; assert(!ReadAuto(1, &value, &unsupported) && !value);

    // No built-in display / no sensor: unsupported, and nothing is written.
    assert(ReadAuto(0, &value, &unsupported) && unsupported);
    FakeHas = 0; unsupported = NO;
    assert(ReadAuto(1, &value, &unsupported) && unsupported);
    assert(WriteAuto(1, YES) && FakeSets == 0);
    FakeHas = 1;

    // Read errors are errors, not unsupported.
    FakeGetResult = (int)0xe00002bc; unsupported = YES;
    assert(ReadAuto(1, &value, &unsupported) && !unsupported);
    assert(WriteAuto(1, YES) && FakeSets == 0); // a failed pre-read blocks the write
    FakeGetResult = 0;

    // ABI mismatch: getter that never writes, or writes a non-boolean byte.
    FakeSkipWrite = YES; assert(ReadAuto(1, &value, NULL)); FakeSkipWrite = NO;
    FakeByte = 2; assert(ReadAuto(1, &value, NULL));
    FakeByte = 1; FakeWide = YES; assert(ReadAuto(1, &value, NULL)); FakeWide = NO; // int-sized write is refused
    FakeByte = 0;

    // Writes: accepted + confirmed, rejected, and "success" without matching readback.
    assert(!WriteAuto(1, YES) && FakeByte == 1 && FakeSets == 1);
    assert(!WriteAuto(1, NO) && FakeByte == 0 && FakeSets == 2);
    FakeSetResult = (int)0xe00002bc; assert(WriteAuto(1, YES) && FakeByte == 0);
    FakeSetResult = 0; FakeIgnoreSet = YES; assert(WriteAuto(1, YES) && FakeByte == 0);

    // Real symbols: read-only, environment-specific, reported rather than asserted.
    AutoBackend real = {0};
    NSString *issue = LoadBackend(&real, BackendPath);
    printf("INFO: DisplayServices symbols on this Mac: %s\n", issue ? issue.UTF8String : "present");
    printf("INFO: built-in display id on this Mac: %u; fake id %u\n", BuiltInDisplay(), FakeDisplay());
    puts("PASS: unavailable symbols, unsupported Macs, read errors, ABI mismatch, rejected writes, and unconfirmed writes.");
    return 0;
} }
