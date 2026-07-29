// TSTAccessibility.m
// The accessibility-tree bridge. AXPTranslator (a process-wide singleton in our
// host process) is wired with a token delegate; each property read on a
// translated element triggers a synchronous callback that we satisfy by issuing
// an async XPC request to the simulator and blocking on a dispatch group.
//
// Reimplemented from the documented AXPTranslationTokenDelegateHelper protocol.
#import "TSTAccessibility.h"
#import "TSTPrivateAPI.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@interface TSTAXDispatcher () {
  NSMutableDictionary<NSString *, id> *_tokenToDevice;
  dispatch_queue_t _callbackQueue;
  id _translator;
}
@property (atomic, readwrite) BOOL lastRequestTimedOut;
@end

@implementation TSTAXDispatcher

+ (instancetype)shared {
  static TSTAXDispatcher *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[TSTAXDispatcher alloc] init]; });
  return shared;
}

- (instancetype)init {
  self = [super init];
  if (!self) return nil;
  _tokenToDevice = [NSMutableDictionary dictionary];
  _callbackQueue = dispatch_queue_create("com.testa.ax.callback", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (id)translator {
  if (!_translator) {
    Class cls = objc_getClass("AXPTranslator");
    if (cls) {
      _translator = [(id<TSTAXPTranslatorClass>)cls sharedInstance];
      [(id<TSTAXPTranslator>)_translator setBridgeTokenDelegate:self];
    }
  }
  return _translator;
}

- (void)registerToken:(NSString *)token device:(id)device {
  @synchronized (_tokenToDevice) { _tokenToDevice[token] = device; }
}

- (void)unregisterToken:(NSString *)token {
  @synchronized (_tokenToDevice) { [_tokenToDevice removeObjectForKey:token]; }
}

- (void)resetRequestTimeout {
  self.lastRequestTimedOut = NO;
}

#pragma mark AXPTranslationTokenDelegateHelper

// Returns a block ^AXPTranslatorResponse *(AXPTranslatorRequest *). Because the
// CoreSimulator API is async but AXPTranslator calls us synchronously, we bridge
// with a dispatch group. The completion runs on _callbackQueue (never main).
- (id (^)(id))accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  id device = nil;
  @synchronized (_tokenToDevice) { device = _tokenToDevice[token]; }
  dispatch_queue_t cbq = _callbackQueue;
  if (!device) {
    return ^id(id axRequest) {
      return [(id<TSTAXPResponseClass>)objc_getClass("AXPTranslatorResponse") emptyResponse];
    };
  }
  __weak TSTAXDispatcher *weakSelf = self;
  return ^id(id axRequest) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    __block id response = nil;
    [(id<TSTSimDevice>)device sendAccessibilityRequestAsync:axRequest
                                            completionQueue:cbq
                                          completionHandler:^(id innerResponse) {
      response = innerResponse;
      dispatch_group_leave(group);
    }];
    long waited = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
    if (waited != 0 || !response) {
      // The simulator did not answer. Flag it so the caller can stop walking:
      // once one read times out, the rest almost always will too.
      weakSelf.lastRequestTimedOut = YES;
      response = [(id<TSTAXPResponseClass>)objc_getClass("AXPTranslatorResponse") emptyResponse];
    }
    return response;
  };
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token {
  return rect;
}

- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
  return nil;
}

@end
