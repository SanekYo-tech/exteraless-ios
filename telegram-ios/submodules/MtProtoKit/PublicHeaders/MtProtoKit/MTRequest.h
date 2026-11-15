

#import <Foundation/Foundation.h>
#import <MtProtoKit/MTRequestLogContext.h>

@class MTRequestContext;
@class MTRequestErrorContext;
@class MTRpcError;

@interface MTRequestResponseInfo : NSObject

@property (nonatomic, readonly) int32_t networkType;
@property (nonatomic, readonly) double timestamp;
@property (nonatomic, readonly) double duration;

- (instancetype _Null_unspecified)initWithNetworkType:(int32_t)networkType timestamp:(double)timestamp duration:(double)duration;

@end

@interface MTRequest : NSObject

@property (nonatomic, strong, readonly) id _Null_unspecified internalId;

@property (nonatomic, strong, readonly) NSData * _Null_unspecified payload;
@property (nonatomic, strong, readonly) id _Null_unspecified metadata;
@property (nonatomic, strong, readonly) id _Null_unspecified shortMetadata;
/// Immutable context value, established during payload setup; replacements may
/// only strengthen its classification. Does not alter metadata used by dependencies.
@property (nonatomic, strong, readonly) MTRequestLogContext * _Null_unspecified logContext;
@property (nonatomic, strong, readonly) id _Null_unspecified metadataForLogging;
@property (nonatomic, strong, readonly) id _Null_unspecified shortMetadataForLogging;
@property (nonatomic, strong, readonly) id _Null_unspecified (^ _Null_unspecified responseParser)(NSData * _Null_unspecified);

@property (nonatomic, strong) NSArray * _Null_unspecified decorators;
@property (nonatomic) int32_t transactionResetStateVersion;
@property (nonatomic, strong) MTRequestContext * _Null_unspecified requestContext;
@property (nonatomic, strong) MTRequestErrorContext * _Null_unspecified errorContext;
/// The request went out under a message id and the server may have run it; cleared when the server
/// answers it with an error after which it goes again. Kept when its message id is forgotten (a
/// transaction that may have failed, a session change), for a handover (`handOverRequests:`).
@property (nonatomic, direct) bool mayHaveReachedServer;
@property (nonatomic) bool hasHighPriority;
@property (nonatomic) bool dependsOnPasswordEntry;
@property (nonatomic) bool passthroughPasswordEntryError;
@property (nonatomic) bool needsTimeoutTimer;
@property (nonatomic) int32_t expectedResponseSize;

@property (nonatomic, copy) void (^ _Null_unspecified completed)(id _Null_unspecified result, MTRequestResponseInfo * _Null_unspecified info, MTRpcError * _Null_unspecified error);
@property (nonatomic, copy) void (^ _Null_unspecified progressUpdated)(float progress, NSUInteger packetLength);
@property (nonatomic, copy) void (^ _Null_unspecified acknowledgementReceived)();

@property (nonatomic, copy) bool (^ _Null_unspecified shouldContinueExecutionWithErrorContext)(MTRequestErrorContext * _Null_unspecified errorContext);
@property (nonatomic, copy) bool (^ _Null_unspecified shouldDependOnRequest)(MTRequest * _Null_unspecified anotherRequest);

- (bool)scanNeedsTimeoutTimer __attribute__((objc_direct));
- (MTRequestErrorContext * _Null_unspecified)scanErrorContext __attribute__((objc_direct));
- (id _Null_unspecified)scanInternalId __attribute__((objc_direct));

- (void)setPayload:(NSData * _Null_unspecified)payload metadata:(id _Null_unspecified)metadata shortMetadata:(id _Null_unspecified)shortMetadata responseParser:(id _Null_unspecified (^ _Null_unspecified)(NSData * _Null_unspecified))responseParser;
- (instancetype _Nonnull)initWithLogContext:(MTRequestLogContext * _Nullable)logContext;

@end
