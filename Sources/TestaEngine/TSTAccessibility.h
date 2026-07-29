// TSTAccessibility.h — the shared AXPTranslator token delegate.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSTAXDispatcher : NSObject
+ (instancetype)shared;
/// The AXPTranslator singleton, wired to this dispatcher (lazily).
- (nullable id)translator;
- (void)registerToken:(NSString *)token device:(id)device;
- (void)unregisterToken:(NSString *)token;

/// YES once a bridged accessibility request has hit its 10 s timeout. A dead or
/// wedged simulator times out every single read, so a tree walk that sees this
/// must abort instead of burning 10 s × thousands of elements.
@property (atomic, readonly) BOOL lastRequestTimedOut;

/// Clear -lastRequestTimedOut. Call at the start of every walk.
- (void)resetRequestTimeout;
@end

NS_ASSUME_NONNULL_END
