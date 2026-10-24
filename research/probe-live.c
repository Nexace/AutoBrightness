// Research probe: reads (and with "flip" reversibly toggles) the built-in display's auto brightness.
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
typedef bool (*HasFn)(uint32_t);
typedef int (*GetFn)(uint32_t, bool *);
typedef int (*SetFn)(uint32_t, bool);
static GetFn get; static SetFn set; static uint32_t disp; static int orig = -1;
static void restore(int s) { (void)s; if (orig >= 0) { int r = set(disp, orig); printf("restore(%d) -> 0x%x\n", orig, r); } _exit(1); }
int main(int argc, char **argv) {
  void *h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
  HasFn has = dlsym(h, "DisplayServicesHasAmbientLightCompensation");
  get = dlsym(h, "DisplayServicesAmbientLightCompensationEnabled");
  set = dlsym(h, "DisplayServicesEnableAmbientLightCompensation");
  uint32_t ids[8]; uint32_t n = 0; CGGetActiveDisplayList(8, ids, &n);
  for (uint32_t i = 0; i < n; i++) {
    bool b = CGDisplayIsBuiltin(ids[i]); bool v = 0; int r = get(ids[i], &v);
    printf("display %u builtin=%d has=%d get=0x%x value=%d\n", ids[i], b, has(ids[i]), r, v);
    if (b) disp = ids[i];
  }
  if (!disp || argc < 2 || strcmp(argv[1], "flip")) return 0;
  bool v = 0; if (get(disp, &v)) return 2; orig = v;
  signal(SIGINT, restore); signal(SIGTERM, restore);
  for (int k = 0; k < 2; k++) {
    bool target = k == 0 ? !orig : orig; int r = set(disp, target); bool rb = 0; int g = get(disp, &rb);
    printf("set(%d)=0x%x readback=%d (get=0x%x)\n", target, r, rb, g);
  }
  bool fin = 0; get(disp, &fin); printf("final=%d original=%d %s\n", fin, orig, fin == orig ? "RESTORED" : "MISMATCH");
  return fin != orig;
}
