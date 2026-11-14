#import <UIKit/UIKit.h>
#import "runtime_probe.h"
#include <stdlib.h>
#include <stdio.h>

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

    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *home = [resources stringByAppendingPathComponent:@"python-stdlib"];
    NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.12"];
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSError *directoryError = nil;
    if (!documents || ![NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        fprintf(stderr, "EXL_PROBE_REPORT_DIRECTORY_FAILED: %s\n", directoryError.description.UTF8String ?: "missing Documents path");
        fflush(stderr);
        exit(16);
    }
    NSString *report = [documents stringByAppendingPathComponent:@"runtime-smoke.json"];
    [@"{\"ok\":false,\"phase\":\"app-started\"}\n" writeToFile:report atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // All interpreter creation/destruction stays on this one native thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = EXLRunRuntimeProbe(home.UTF8String, stdlib.UTF8String, dynload.UTF8String, report.UTF8String);
        NSData *previous = [NSData dataWithContentsOfFile:report];
        NSMutableDictionary *result = previous ? [[NSJSONSerialization JSONObjectWithData:previous options:0 error:nil] mutableCopy] : nil;
        if (![result isKindOfClass:NSMutableDictionary.class]) result = [NSMutableDictionary dictionary];
        result[@"native_completed"] = @YES;
        result[@"native_exit_status"] = @(status);
        if (status != 0) result[@"ok"] = @NO;
        [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:report atomically:YES];
        fprintf(stderr, "EXL_PROBE_FINISHED status=%d report=%s\n", status, report.UTF8String);
        fflush(stderr);
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

int main(int argc, char **argv) {
    @autoreleasepool {
        fprintf(stderr, "EXL_PROBE_MAIN_ENTERED\n");
        fflush(stderr);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(EXLProbeDelegate.class));
    }
}
