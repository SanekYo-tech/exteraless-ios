#import <MtProtoKit/MTRequestLogContext.h>

@interface MTRequestLogContext ()
- (instancetype)initWithMethod:(NSString *)method credentials:(bool)credentials;
@end

@implementation MTRequestLogContext

- (instancetype)initWithMethod:(NSString *)method credentials:(bool)credentials {
    self = [super init];
    if (self != nil) {
        _methodName = [method copy];
        _containsCredentials = credentials;
    }
    return self;
}

+ (instancetype)contextForPayload:(NSData *)payload methodName:(NSString *)methodName {
    // Exact constructors from TelegramApi/swift_scheme.tl. The six auth methods
    // are the same set as ExteralessClientAPIRequestPolicy. No substring matching,
    // parameter inspection, token regex, or arbitrary metadata.description call.
    static NSArray<MTRequestLogContext *> *contexts;
    static MTRequestLogContext *ordinary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        contexts = @[
            [[self alloc] initWithMethod:@"bots.invokeWebViewCustomMethod" credentials:true],
            [[self alloc] initWithMethod:@"auth.sendCode" credentials:true],
            [[self alloc] initWithMethod:@"auth.exportLoginToken" credentials:true],
            [[self alloc] initWithMethod:@"auth.importBotAuthorization" credentials:true],
            [[self alloc] initWithMethod:@"auth.importWebTokenAuthorization" credentials:true],
            [[self alloc] initWithMethod:@"auth.initPasskeyLogin" credentials:true],
            [[self alloc] initWithMethod:@"auth.initFirebasePnvLogin" credentials:true]
        ];
        ordinary = [[self alloc] initWithMethod:@"rpc" credentials:false];
    });
    const uint32_t constructors[] = {0x087fc5e7, 0xa677244f, 0xb7e085fe, 0x67a3ff2c, 0x2db873a9, 0x518ad0b7, 0x644f15c0};
    if (payload.length >= 4) {
        const uint8_t *bytes = payload.bytes;
        uint32_t signature = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
        for (NSUInteger i = 0; i < contexts.count; i++) {
            if (signature == constructors[i]) { return contexts[i]; }
        }
    }
    // An exact name can only add protection, never override a protected payload.
    for (MTRequestLogContext *context in contexts) {
        if ([context.methodName isEqualToString:methodName]) { return context; }
    }
    return ordinary;
}

+ (instancetype)redactedUnattributedContext {
    static MTRequestLogContext *context;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ context = [[self alloc] initWithMethod:@"unattributed" credentials:true]; });
    return context;
}

- (instancetype)mergingContext:(MTRequestLogContext *)other {
    return self.containsCredentials ? self : other;
}

- (id)copyWithZone:(NSZone * _Nullable)__unused zone { return self; }

- (NSString *)redactedErrorCategory { return @"CREDENTIAL_RPC_ERROR"; }

- (NSString *)metadataDescription:(id)metadata {
    if (self.containsCredentials) { return [self.methodName stringByAppendingString:@" [CREDENTIAL_REQUEST]"]; }
    return [metadata description] ?: @"rpc";
}

- (NSString *)responseDescription:(id)response {
    if (self.containsCredentials) { return [self.methodName stringByAppendingString:@" [CREDENTIAL_RESPONSE]"]; }
    return [response description] ?: @"nil";
}

- (NSString *)errorDescriptionWithCode:(int32_t)code text:(NSString *)text {
    return [NSString stringWithFormat:@"%@ code=%d %@", self.methodName, (int)code,
        self.containsCredentials ? self.redactedErrorCategory : (text ?: @"")];
}

- (NSString *)description { return self.methodName; }

@end
