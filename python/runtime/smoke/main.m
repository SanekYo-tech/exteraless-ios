#import <Foundation/Foundation.h>
#ifndef EXL_SIMULATOR_COMPONENT
#import <UIKit/UIKit.h>
#endif
#import "runtime_probe.h"
#import "engine_probe.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static int RunProbe(NSString *report, BOOL engine) {
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *home = [resources stringByAppendingPathComponent:@"python-stdlib"];
    NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.12"];
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:report.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "EXL_PROBE_REPORT_DIRECTORY_FAILED: %s\n", error.description.UTF8String);
        return 16;
    }
    fprintf(stderr, "EXL_PROBE_RESOURCES %s\n", resources.UTF8String);
    const char *executable = NSBundle.mainBundle.executablePath.UTF8String;
    int status = engine
        ? EXLRunEngineProbe(home.UTF8String, stdlib.UTF8String, dynload.UTF8String, executable, report.UTF8String)
        : EXLRunRuntimeProbe(home.UTF8String, stdlib.UTF8String, dynload.UTF8String, executable, report.UTF8String);
    NSData *previous = [NSData dataWithContentsOfFile:report];
    NSMutableDictionary *result = previous ? [[NSJSONSerialization JSONObjectWithData:previous options:0 error:nil] mutableCopy] : nil;
    if (![result isKindOfClass:NSMutableDictionary.class]) result = [NSMutableDictionary dictionary];
    result[@"native_completed"] = @YES;
    result[@"native_exit_status"] = @(status);
    if (status != 0) result[@"ok"] = @NO;
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:report atomically:YES];
    fprintf(stderr, "EXL_PROBE_FINISHED status=%d report=%s\n", status, report.UTF8String);
    fflush(stderr);
    return status;
}

#ifndef EXL_SIMULATOR_COMPONENT
@interface EXLProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation EXLProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    fprintf(stderr, "EXL_PROBE_APP_STARTED\n");
    fflush(stderr);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [[UIViewController alloc] init];
    UILabel *label = [[UILabel alloc] initWithFrame:controller.view.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"Checking embedded CPython and the native bridge…";
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *report = [documents stringByAppendingPathComponent:@"runtime-smoke.json"];
    // Process initialization/finalization stay on this callback's native thread;
    // the engine probe creates and joins its own interpreter worker threads.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = RunProbe(report, YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            label.text = status == 0 ? @"CPython 3.12 + native bridge: OK" : [NSString stringWithFormat:@"Runtime probe failed (%d)", status];
            NSLog(@"Runtime probe status=%d report=%@", status, report);
            if ([NSProcessInfo.processInfo.arguments containsObject:@"--ci-exit"]) {
                exit(status);
            }
        });
    });
    return YES;
}
@end
#endif

int main(int argc, char **argv) {
    @autoreleasepool {
        fprintf(stderr, "EXL_PROBE_MAIN_ENTERED\n");
        fflush(stderr);
        // Both CLI modes execute the native probes. Simulator builds use a
        // Foundation-only entry point; the device artifact has a UIKit display.
        if (argc == 3 && strcmp(argv[1], "--headless-report") == 0) {
            return RunProbe([NSString stringWithUTF8String:argv[2]], NO);
        }
        if (argc == 3 && strcmp(argv[1], "--engine-report") == 0) {
            return RunProbe([NSString stringWithUTF8String:argv[2]], YES);
        }
#ifdef EXL_SIMULATOR_COMPONENT
        fputs("usage: ExteralessPythonSmoke --headless-report|--engine-report report.json\n", stderr);
        return 2;
#else
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(EXLProbeDelegate.class));
#endif
    }
}
