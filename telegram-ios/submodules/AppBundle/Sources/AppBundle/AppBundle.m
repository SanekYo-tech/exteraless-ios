#import <AppBundle/AppBundle.h>
#import <os/lock.h>
#import <objc/runtime.h>

static os_unfair_lock exteralessImageProviderLock = OS_UNFAIR_LOCK_INIT;
static UIImage * _Nullable (^exteralessImageProvider)(NSString * _Nonnull);
static char exteralessBundleImageNameKey;

NSString * _Nullable exteralessAppBundleImageName(UIImage * _Nullable image) {
    return objc_getAssociatedObject(image, &exteralessBundleImageNameKey);
}

void setExteralessAppBundleImageProvider(UIImage * _Nullable (^ _Nullable provider)(NSString * _Nonnull)) {
    os_unfair_lock_lock(&exteralessImageProviderLock);
    exteralessImageProvider = [provider copy];
    os_unfair_lock_unlock(&exteralessImageProviderLock);
}

UIImage * _Nullable exteralessAppBundleImage(NSString * _Nonnull name) {
    os_unfair_lock_lock(&exteralessImageProviderLock);
    UIImage * _Nullable (^provider)(NSString * _Nonnull) = [exteralessImageProvider copy];
    os_unfair_lock_unlock(&exteralessImageProviderLock);
    return provider == nil ? nil : provider(name);
}

NSBundle * _Nonnull getAppBundle() {
    static NSBundle *appBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        if ([[bundle.bundleURL pathExtension] isEqualToString:@"appex"]) {
            bundle = [NSBundle bundleWithURL:[[bundle.bundleURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent]];
        } else if ([[bundle.bundleURL pathExtension] isEqualToString:@"framework"]) {
            bundle = [NSBundle bundleWithURL:[[bundle.bundleURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent]];
        } else if ([[bundle.bundleURL pathExtension] isEqualToString:@"Frameworks"]) {
            bundle = [NSBundle bundleWithURL:[bundle.bundleURL URLByDeletingLastPathComponent]];
        }
        appBundle = bundle;
    });
    
    return appBundle;
}

@implementation UIImage (AppBundle)

- (instancetype _Nullable)initWithBundleImageName:(NSString * _Nonnull)bundleImageName {
    UIImage *image = exteralessAppBundleImage(bundleImageName) ?: [UIImage imageNamed:bundleImageName inBundle:getAppBundle() compatibleWithTraitCollection:nil];
    if (image != nil && [bundleImageName hasPrefix:@"Chat List/Tabs/"]) {
        objc_setAssociatedObject(image, &exteralessBundleImageNameKey, bundleImageName, OBJC_ASSOCIATION_COPY);
    }
    return image;
}

@end
