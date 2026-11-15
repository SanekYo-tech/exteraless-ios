#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable logging-only classification. Known credential methods use interned
/// contexts with canonical, compiled method names, never a parameter/description.
@interface MTRequestLogContext : NSObject <NSCopying>
@property (nonatomic, readonly) bool containsCredentials;
@property (nonatomic, copy, readonly) NSString *methodName;

+ (instancetype)contextForPayload:(NSData * _Nullable)payload methodName:(NSString * _Nullable)methodName NS_SWIFT_NAME(context(payload:methodName:));
+ (instancetype)redactedUnattributedContext NS_SWIFT_NAME(redactedUnattributed());
- (instancetype)mergingContext:(MTRequestLogContext *)other NS_SWIFT_NAME(merging(_:));
- (NSString *)metadataDescription:(id _Nullable)metadata NS_SWIFT_NAME(metadataDescription(_:));
- (NSString *)responseDescription:(id _Nullable)response NS_SWIFT_NAME(responseDescription(_:));
- (NSString *)errorDescriptionWithCode:(int32_t)code text:(NSString * _Nullable)text NS_SWIFT_NAME(errorDescription(code:text:));
/// A fixed category for telemetry/logging only; never replace the actual RPC error.
@property (nonatomic, copy, readonly) NSString *redactedErrorCategory;
@end

NS_ASSUME_NONNULL_END
