#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NSBundle * _Nonnull getAppBundle(void);

// Optional in-app icon replacement. Nil means the original bundled asset. The
// provider must be thread-safe and must not call initWithBundleImageName again.
void setExteralessAppBundleImageProvider(UIImage * _Nullable (^ _Nullable provider)(NSString * _Nonnull));
UIImage * _Nullable exteralessAppBundleImage(NSString * _Nonnull name);
NSString * _Nullable exteralessAppBundleImageName(UIImage * _Nullable image);

@interface UIImage (AppBundle)

- (instancetype _Nullable)initWithBundleImageName:(NSString * _Nonnull)bundleImageName;

@end
