#import <Foundation/Foundation.h>

@class MTSignal;

NS_ASSUME_NONNULL_BEGIN

/// Narrow app resolver boundary; independent of CPython and plugin bridges.
/// The app installs it before accounts are created. Extensions can leave it unset.
@interface MTAppNetworkResolver : NSObject
+ (void)installResolver:(MTSignal * _Nonnull (^)(NSString *, uint16_t))resolver
         cacheLifetime:(NSTimeInterval (^)(NSString *, uint16_t))cacheLifetime
            preference:(NSInteger)preference;
+ (void)updatePreference:(NSInteger)preference;
+ (void)invalidateCaches;
+ (NSInteger)addressFamilyPreference; // -1 stock, 0 IPv4 first, 1 IPv6 first
+ (MTSignal * _Nullable)resolveHost:(NSString *)host port:(uint16_t)port;
/// Cancellable native DNS-SD query. Emits [{data: NSData, ttl: NSNumber}].
+ (MTSignal *)systemQuery:(NSString *)host type:(uint16_t)type;
@end

FOUNDATION_EXPORT NSNotificationName const MTAppNetworkResolverDidChange;

/// Called ONLY on a Rust resolver worker. UTF-8 newline-separated IP literals.
/// 0 = not installed (use backend native resolver); -1 = failed; >0 = bytes.
/// The output is never NUL-terminated implicitly and never contains a hostname.
FOUNDATION_EXPORT int32_t MTAppNetworkResolve(const char *host, uint16_t port, char *output, size_t capacity,
    bool (* _Nullable shouldCancel)(const void * _Nullable), const void * _Nullable cancelContext);
FOUNDATION_EXPORT uint64_t MTAppNetworkResolverEpoch(void);
/// -1 when uninstalled; otherwise remaining positive cache TTL in seconds.
FOUNDATION_EXPORT double MTAppNetworkResolverCacheLifetime(const char *host, uint16_t port);

NS_ASSUME_NONNULL_END
