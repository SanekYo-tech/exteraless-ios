#import <UIKit/UIKit.h>
#include <signal.h>
#include <unistd.h>

// A process-local hard bound, independent of UIKit's main run loop or Python's
// GIL. No SDK code installs signal handlers in this harness. _exit is async-safe.
static void client_harness_deadline(int signal_number) {
    (void)signal_number;
    _exit(124);
}

int main(int argc, char *argv[]) {
    signal(SIGALRM, client_harness_deadline);
    alarm(30);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"ClientUIHarnessAppDelegate");
    }
}
