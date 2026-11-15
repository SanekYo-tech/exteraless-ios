#import <MtProtoKit/MTAppNetworkResolver.h>
#import <MtProtoKit/MTSignal.h>
#import <MtProtoKit/MTDisposable.h>
#import <dns_sd.h>
#import <stdatomic.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <stdlib.h>
#import <string.h>

NSNotificationName const MTAppNetworkResolverDidChange = @"MTAppNetworkResolverDidChange";
static MTSignal *(^appResolve)(NSString *, uint16_t);
static NSTimeInterval (^appCacheLifetime)(NSString *, uint16_t);
static NSInteger appPreference = -1;
static _Atomic(uint64_t) appEpoch = 0;

@interface MTAppSystemQuery : NSObject
@property (nonatomic) DNSServiceRef service;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) MTSubscriber *subscriber;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *records;
@property (nonatomic) uint16_t type;
@property (nonatomic) BOOL finished;
- (void)close;
- (void)receiveFlags:(DNSServiceFlags)flags error:(DNSServiceErrorType)error type:(uint16_t)type data:(const void *)data length:(uint16_t)length ttl:(uint32_t)ttl interfaceIndex:(uint32_t)interfaceIndex;
@end

static void MTAppSystemQueryReply(__unused DNSServiceRef service, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error, __unused const char *name, uint16_t type, __unused uint16_t recordClass, uint16_t length, const void *data, uint32_t ttl, void *context) {
    MTAppSystemQuery *query = (__bridge MTAppSystemQuery *)context;
    [query receiveFlags:flags error:error type:type data:data length:length ttl:ttl interfaceIndex:interfaceIndex];
}

@implementation MTAppSystemQuery
- (void)close {
    self.finished = YES;
    if (self.service != NULL) { DNSServiceRefDeallocate(self.service); self.service = NULL; }
}
- (void)receiveFlags:(DNSServiceFlags)flags error:(DNSServiceErrorType)error type:(uint16_t)type data:(const void *)data length:(uint16_t)length ttl:(uint32_t)ttl interfaceIndex:(uint32_t)interfaceIndex {
    if (self.finished) { return; }
    if (error != kDNSServiceErr_NoError) {
        [self close];
        if (error == kDNSServiceErr_NoSuchRecord) { [self.subscriber putNext:@[]]; [self.subscriber putCompletion]; }
        else { [self.subscriber putError:@(error)]; }
        self.subscriber = nil;
        return;
    }
    if (type != self.type) { return; }
    if ((flags & kDNSServiceFlagsAdd) != 0 && data != NULL && self.records.count < 64) {
        [self.records addObject:@{@"data": [NSData dataWithBytes:data length:length], @"ttl": @(ttl), @"interfaceIndex": @(interfaceIndex)}];
    }
    if ((flags & kDNSServiceFlagsMoreComing) == 0) {
        NSArray *records = [self.records copy];
        [self close];
        [self.subscriber putNext:records];
        [self.subscriber putCompletion];
        self.subscriber = nil;
    }
}
@end

@implementation MTAppNetworkResolver
+ (void)installResolver:(MTSignal *(^)(NSString *, uint16_t))resolver cacheLifetime:(NSTimeInterval (^)(NSString *, uint16_t))cacheLifetime preference:(NSInteger)preference {
    @synchronized(self) { appResolve = [resolver copy]; appCacheLifetime = [cacheLifetime copy]; appPreference = preference; }
    [self invalidateCaches];
}
+ (void)updatePreference:(NSInteger)preference {
    @synchronized(self) { appPreference = preference; }
    [self invalidateCaches];
}
+ (void)invalidateCaches {
    atomic_fetch_add_explicit(&appEpoch, 1, memory_order_release);
    [[NSNotificationCenter defaultCenter] postNotificationName:MTAppNetworkResolverDidChange object:nil];
}
+ (NSInteger)addressFamilyPreference { @synchronized(self) { return appPreference; } }
+ (MTSignal *)resolveHost:(NSString *)host port:(uint16_t)port {
    MTSignal *(^resolve)(NSString *, uint16_t);
    @synchronized(self) { resolve = appResolve; }
    return resolve == nil ? nil : resolve(host, port);
}
+ (MTSignal *)systemQuery:(NSString *)host type:(uint16_t)type {
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        MTAppSystemQuery *query = [[MTAppSystemQuery alloc] init];
        query.queue = dispatch_queue_create("Exteraless.SystemDNS", DISPATCH_QUEUE_SERIAL);
        query.subscriber = subscriber;
        query.records = [[NSMutableArray alloc] init];
        query.type = type;
        dispatch_async(query.queue, ^{
            if (query.finished) { return; }
            DNSServiceRef service = NULL;
            DNSServiceErrorType error = DNSServiceQueryRecord(&service, kDNSServiceFlagsTimeout, kDNSServiceInterfaceIndexAny, host.UTF8String, type, kDNSServiceClass_IN, MTAppSystemQueryReply, (__bridge void *)query);
            query.service = service;
            if (error == kDNSServiceErr_NoError) { error = DNSServiceSetDispatchQueue(service, query.queue); }
            if (error != kDNSServiceErr_NoError) {
                [query close]; [subscriber putError:@(error)]; query.subscriber = nil;
            }
        });
        return [[MTBlockDisposable alloc] initWithBlock:^{
            dispatch_async(query.queue, ^{ [query close]; query.subscriber = nil; });
        }];
    }];
}
@end

uint64_t MTAppNetworkResolverEpoch(void) { return atomic_load_explicit(&appEpoch, memory_order_acquire); }

double MTAppNetworkResolverCacheLifetime(const char *host, uint16_t port) {
    if (host == NULL) { return 0; }
    NSTimeInterval (^lifetime)(NSString *, uint16_t);
    @synchronized([MTAppNetworkResolver class]) { lifetime = appCacheLifetime; }
    if (lifetime == nil) { return -1; }
    NSString *name = [NSString stringWithUTF8String:host];
    return name == nil ? 0 : lifetime(name, port);
}

int32_t MTAppNetworkResolve(const char *host, uint16_t port, char *output, size_t capacity, bool (*shouldCancel)(const void *), const void *cancelContext) {
    if (host == NULL || output == NULL || capacity == 0 || port == 0 || [NSThread isMainThread]) { return -1; }
    if (shouldCancel != NULL && shouldCancel(cancelContext)) { return -1; }
    @autoreleasepool {
        NSString *name = [NSString stringWithUTF8String:host];
        if (name == nil || name.length > 253) { return -1; }
        MTSignal *signal = [MTAppNetworkResolver resolveHost:name port:port];
        if (signal == nil) { return 0; }
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSLock *lock = [[NSLock alloc] init];
        __block NSData *result = nil;
        __block BOOL finished = NO;
        void (^finish)(NSArray *) = ^(NSArray *addresses) {
            [lock lock];
            if (!finished) {
                finished = YES;
                if ([addresses isKindOfClass:[NSArray class]] && addresses.count > 0 && addresses.count <= 16) {
                    NSMutableArray *valid = [[NSMutableArray alloc] init];
                    for (id address in addresses) {
                        if (![address isKindOfClass:[NSString class]]) { continue; }
                        struct in_addr v4; struct in6_addr v6;
                        NSArray<NSString *> *parts = [address componentsSeparatedByString:@"%"];
                        NSString *ip = parts.firstObject;
                        if (parts.count == 1 && inet_pton(AF_INET, ip.UTF8String, &v4) == 1) { [valid addObject:ip]; }
                        else if (parts.count <= 2 && inet_pton(AF_INET6, ip.UTF8String, &v6) == 1) {
                            if (parts.count == 1) { [valid addObject:ip]; }
                            else {
                                NSString *scope = parts[1];
                                unsigned int index = if_nametoindex(scope.UTF8String);
                                if (index == 0 && scope.length > 0 && [scope rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
                                    unsigned long long number = strtoull(scope.UTF8String, NULL, 10);
                                    if (number <= UINT32_MAX) { index = (unsigned int)number; }
                                }
                                if (index != 0) { [valid addObject:[NSString stringWithFormat:@"%@%%%u", ip, index]]; }
                            }
                        }
                    }
                    if (valid.count > 0) { result = [[valid componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]; }
                }
                dispatch_semaphore_signal(semaphore);
            }
            [lock unlock];
        };
        id<MTDisposable> disposable = [signal startWithNext:^(id value) { finish(value); } error:^(__unused id error) { finish(nil); } completed:^{ finish(nil); }];
        // No unbounded wait: cancellation from the last Rust session is observed
        // within 50 ms, even if DNS-SD/URLSession has not called back yet.
        for (int tick = 0; tick < 110; tick++) {
            if (shouldCancel != NULL && shouldCancel(cancelContext)) { break; }
            if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) { break; }
        }
        [lock lock]; finished = YES; NSData *bytes = result; [lock unlock];
        [disposable dispose];
        if (shouldCancel != NULL && shouldCancel(cancelContext)) { return -1; }
        if (bytes.length == 0 || bytes.length > capacity || bytes.length > INT32_MAX) { return -1; }
        memcpy(output, bytes.bytes, bytes.length);
        return (int32_t)bytes.length;
    }
}
