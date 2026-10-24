// A scriptable stand-in for the DisplayServices functions, shared by the checks.
static uint8_t FakeHas = 1, FakeByte = 1;
static int FakeGetResult, FakeSetResult, FakeSets;
static BOOL FakeSkipWrite, FakeIgnoreSet, FakeWide;
static uint8_t FakeHasFn(uint32_t display) { (void)display; return FakeHas; }
static int FakeGetFn(uint32_t display, bool *enabled) {
    (void)display;
    if (FakeGetResult) return FakeGetResult;
    if (!FakeSkipWrite) *(uint8_t *)enabled = FakeByte;
    if (FakeWide) *(uint32_t *)enabled = FakeByte; // an ABI that writes an int, not a byte
    return 0;
}
static int FakeSetFn(uint32_t display, bool enabled) {
    (void)display;
    FakeSets++;
    if (FakeSetResult) return FakeSetResult;
    if (!FakeIgnoreSet) FakeByte = enabled;
    return 0;
}
static CGDirectDisplayID FakeDisplay(void) { return 1; }
static void ResetFake(void) {
    FakeHas = 1; FakeByte = 1; FakeGetResult = 0; FakeSetResult = 0; FakeSets = 0; FakeSkipWrite = NO; FakeIgnoreSet = NO; FakeWide = NO;
    Backend = (AutoBackend){ FakeHasFn, FakeGetFn, FakeSetFn };
}
