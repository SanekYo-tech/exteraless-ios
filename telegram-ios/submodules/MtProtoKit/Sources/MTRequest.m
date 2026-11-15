#import <MtProtoKit/MTRequest.h>

#import <MtProtoKit/MTRpcError.h>

#import <os/lock.h>
#import <libkern/OSAtomic.h>

@implementation MTRequestResponseInfo

- (instancetype)initWithNetworkType:(int32_t)networkType timestamp:(double)timestamp duration:(double)duration {
    self = [super init];
    if (self != nil) {
        _networkType = networkType;
        _timestamp = timestamp;
        _duration = duration;
    }
    return self;
}

@end

@interface MTRequestInternalId : NSObject <NSCopying>
{
    NSUInteger _value;
}

@end

@implementation MTRequestInternalId

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        static int32_t nextValue = 1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _value = OSAtomicIncrement32(&nextValue);
#pragma clang diagnostic pop
    }
    return self;
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[MTRequestInternalId class]] && ((MTRequestInternalId *)object)->_value == _value;
}

- (NSUInteger)hash
{
    return _value;
}

- (instancetype)copyWithZone:(NSZone *)__unused zone
{
    MTRequestInternalId *another = [[MTRequestInternalId alloc] init];
    if (another != nil)
        another->_value = _value;
    return another;
}

@end

@implementation MTRequest

- (bool)scanNeedsTimeoutTimer {
    return _needsTimeoutTimer;
}

- (MTRequestErrorContext *)scanErrorContext {
    return _errorContext;
}

- (id)scanInternalId {
    return _internalId;
}

- (instancetype)init
{
    return [self initWithLogContext:nil];
}

- (instancetype)initWithLogContext:(MTRequestLogContext *)logContext
{
    self = [super init];
    if (self != nil)
    {
        _internalId = [[MTRequestInternalId alloc] init];
        _dependsOnPasswordEntry = true;
        _logContext = logContext ?: [MTRequestLogContext contextForPayload:nil methodName:nil];
    }
    return self;
}

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser
{
    _payload = [payload copy];
    NSString *methodName = [shortMetadata isKindOfClass:[NSString class]] ? shortMetadata : nil;
    MTRequestLogContext *inferred = [MTRequestLogContext contextForPayload:_payload methodName:methodName];
    _logContext = [inferred mergingContext:_logContext];
    _metadata = metadata;
    _shortMetadata = shortMetadata;
    _responseParser = [responseParser copy];
}

- (id)metadataForLogging { return _logContext.containsCredentials ? [_logContext metadataDescription:nil] : _metadata; }
- (id)shortMetadataForLogging { return _logContext.containsCredentials ? [_logContext metadataDescription:nil] : _shortMetadata; }

@end
