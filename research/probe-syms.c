#include <dlfcn.h>
#include <stdio.h>
int main(void) {
  const char *libs[] = {"/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"};
  const char *syms[] = {"DisplayServicesAmbientLightCompensationEnabled","DisplayServicesEnableAmbientLightCompensation",
    "DisplayServicesHasAmbientLightCompensation","DisplayServicesCanChangeBrightness","DisplayServicesGetBrightness",
    "DisplayServicesIsSmartDisplay","DisplayServicesRegisterForAmbientLightCompensationNotifications",
    "DisplayServicesGetLinearBrightness","DisplayServicesAutoBrightnessEnabled","DisplayServicesEnableAutoBrightness",
    "DisplayServicesSetAutoBrightness","DisplayServicesGetAutoBrightness", NULL};
  for (int l = 0; l < 2; l++) {
    void *h = dlopen(libs[l], RTLD_LAZY);
    printf("%s -> %s\n", libs[l], h ? "loaded" : dlerror());
    if (!h) continue;
    for (int i = 0; syms[i]; i++) printf("  %-60s %p\n", syms[i], dlsym(h, syms[i]));
  }
}
