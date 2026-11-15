#import <UIKit/UIKit.h>

// An empty resource-bearing XCTest host. The application and acceptance-harness
// delegates have different Objective-C names and are never selected here.
@interface EXLNativeTestsSceneDelegate : NSObject <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation EXLNativeTestsSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];
}
@end

@interface EXLNativeTestsAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation EXLNativeTestsAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([EXLNativeTestsAppDelegate class]));
    }
}
