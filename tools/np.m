// carsurf-notify — post a notify(3) name over SSH to drive a CarSurf toggle.
//
//   carsurf-notify com.pavunato.carsurf/reload com.pavunato.carsurf/application-library-change
//
// The tweak registers these two names (CSConfig.m / CSCarKitPolicy.m). Posting
// them after editing the prefs plist drives a real enable/disable without the
// Settings UI, which is how the device is self-tested.

#include <notify.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <notify-name> [notify-name ...]\n", argv[0]);
        return 2;
    }
    for (int i = 1; i < argc; i++) {
        notify_post(argv[i]);
        printf("posted %s\n", argv[i]);
    }
    return 0;
}
