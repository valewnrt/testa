// TSTSimulator.m
#import "TestaEngine.h"
#import "TSTIndigo.h"
#import "TSTPrivateAPI.h"
#import "TSTAccessibility.h"

#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>

static NSString *const TSTErrorDomain = @"com.testa.engine";

// IndigoHIDMessageForMouseNSEvent(point0, point1, target, eventType, BOOL)
// Returns a heap message; we read its touch payload and rebuild our own.
typedef TSTIndigoMessage *(*TSTMouseEventFn)(CGPoint *p0, CGPoint *p1, int target, int eventType, BOOL flag);
// IndigoHIDMessageForKeyboardArbitrary(usageCode, op) — op 1=down 2=up.
typedef TSTIndigoMessage *(*TSTKeyboardFn)(int keyCode, int op);

static void *gCSHandle = NULL;  // CoreSimulator
static void *gSKHandle = NULL;  // SimulatorKit
static void *gAXHandle = NULL;  // AccessibilityPlatformTranslation

// dlerror() is a one-shot global: it must be read immediately after the dlopen
// that failed, or a later call clobbers it. Capture each one at the source.
static NSString *gCSError = nil;
static NSString *gSKError = nil;
static NSString *gAXError = nil;

// Hard limits for a single accessibility walk. A wedged simulator answers no
// reads at all; without these the daemon hangs forever.
static const NSTimeInterval TSTAXWalkDeadline = 25.0;  // stop descending after this
static const int64_t TSTAXWaitSeconds = 30;            // give up on the walk entirely

// dlopen + capture the error string (nil-safe: dlerror may be invalid UTF-8).
static void *TSTDLOpen(const char *path, NSString * __strong *errOut) {
  dlerror();  // clear any stale error
  void *h = dlopen(path, RTLD_NOW);
  if (!h) {
    const char *e = dlerror();
    NSString *s = e ? [NSString stringWithUTF8String:e] : nil;
    *errOut = s ?: @"unknown dlopen failure";
  } else {
    *errOut = nil;
  }
  return h;
}

static NSError *TSTMakeError(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:TSTErrorDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// Resolve the active developer dir (DEVELOPER_DIR env, else `xcode-select -p`).
static NSString *TSTDeveloperDir(void) {
  const char *env = getenv("DEVELOPER_DIR");
  if (env && strlen(env) > 0) {
    NSString *fromEnv = [NSString stringWithUTF8String:env];  // nil if not UTF-8
    if (fromEnv.length) return fromEnv;
  }
  FILE *fp = popen("/usr/bin/xcode-select -p 2>/dev/null", "r");
  if (!fp) return @"/Applications/Xcode.app/Contents/Developer";
  char buf[1024];
  NSMutableString *out = [NSMutableString string];
  while (fgets(buf, sizeof(buf), fp)) {
    NSString *chunk = [NSString stringWithUTF8String:buf];  // nil on invalid UTF-8
    if (chunk) [out appendString:chunk];
  }
  pclose(fp);
  NSString *trimmed = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return trimmed.length ? trimmed : @"/Applications/Xcode.app/Contents/Developer";
}

@interface TSTSimulator () {
  id<TSTSimDevice> _device;
  id<TSTLegacyHIDClient> _hidClient;
  dispatch_queue_t _hidQueue;
  dispatch_queue_t _axQueue;
  TSTMouseEventFn _mouseFn;
  TSTKeyboardFn _keyboardFn;
  CGSize _pixelSize;
  // Walk state — only ever touched from the serial _axQueue.
  CFAbsoluteTime _walkDeadline;
  BOOL _walkTruncated;
}
@end

@implementation TSTSimulator

#pragma mark - Framework loading

+ (BOOL)loadFrameworks:(NSError **)error {
  static dispatch_once_t once;
  static BOOL ok = NO;
  dispatch_once(&once, ^{
    NSString *dev = TSTDeveloperDir();
    gCSHandle = TSTDLOpen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", &gCSError);
    NSString *skPath = [dev stringByAppendingString:@"/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"];
    gSKHandle = TSTDLOpen(skPath.UTF8String, &gSKError);
    gAXHandle = TSTDLOpen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", &gAXError);
    ok = (gCSHandle != NULL && gSKHandle != NULL);
  });
  if (!ok && error) {
    *error = TSTMakeError(1, [NSString stringWithFormat:
      @"Failed to load private frameworks (CoreSimulator=%p SimulatorKit=%p AccessibilityPlatformTranslation=%p)."
      @" CoreSimulator: %@. SimulatorKit: %@. AccessibilityPlatformTranslation: %@.",
      gCSHandle, gSKHandle, gAXHandle,
      gCSError ?: @"ok", gSKError ?: @"ok", gAXError ?: @"ok"]);
  }
  return ok;
}

#pragma mark - Discovery

+ (nullable instancetype)bootedSimulatorWithError:(NSError **)error {
  return [self simulatorWithUDID:nil error:error];
}

+ (nullable instancetype)simulatorWithUDID:(NSString *)udid error:(NSError **)error {
  if (![self loadFrameworks:error]) return nil;

  Class ctxCls = objc_getClass("SimServiceContext");
  if (!ctxCls) {
    if (error) *error = TSTMakeError(2, @"SimServiceContext class not found");
    return nil;
  }
  NSError *e = nil;
  NSString *dev = TSTDeveloperDir();
  id ctx = [(id<TSTServiceContextClass>)ctxCls sharedServiceContextForDeveloperDir:dev error:&e];
  if (!ctx) {
    if (error) *error = e ?: TSTMakeError(3, @"sharedServiceContextForDeveloperDir failed");
    return nil;
  }
  id set = [(id<TSTServiceContext>)ctx defaultDeviceSetWithError:&e];
  if (!set) {
    if (error) *error = e ?: TSTMakeError(4, @"defaultDeviceSetWithError failed");
    return nil;
  }
  NSArray *devices = [(id<TSTDeviceSet>)set devices];
  id<TSTSimDevice> match = nil;
  for (id<TSTSimDevice> d in devices) {
    BOOL booted = ([d state] == 3); // SimDeviceStateBooted
    if (!booted) continue;
    if (udid) {
      if ([[d UDID].UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) { match = d; break; }
    } else {
      match = d; break;
    }
  }
  if (!match) {
    if (error) *error = TSTMakeError(5, udid
      ? [NSString stringWithFormat:@"No booted simulator with UDID %@", udid]
      : @"No booted simulator found");
    return nil;
  }
  return [[self alloc] initWithDevice:match];
}

- (instancetype)initWithDevice:(id<TSTSimDevice>)device {
  self = [super init];
  if (!self) return nil;
  _device = device;
  _udid = [device UDID].UUIDString;
  _name = [device name];

  id<TSTDeviceType> dt = (id<TSTDeviceType>)[device deviceType];
  CGSize px = [dt mainScreenSize];
  float scale = [dt mainScreenScale];
  if (scale <= 0) scale = 1.0;
  _pixelSize = px;
  _screenScale = scale;
  _screenPointSize = CGSizeMake(px.width / scale, px.height / scale);

  Class hidCls = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient");
  if (hidCls) {
    NSError *e = nil;
    _hidClient = [(id<TSTLegacyHIDClient>)[hidCls alloc] initWithDevice:device error:&e];
  }
  _hidQueue = dispatch_queue_create("com.testa.hid", DISPATCH_QUEUE_SERIAL);
  _axQueue = dispatch_queue_create("com.testa.ax", DISPATCH_QUEUE_SERIAL);
  _mouseFn = (TSTMouseEventFn)dlsym(gSKHandle, "IndigoHIDMessageForMouseNSEvent");
  _keyboardFn = (TSTKeyboardFn)dlsym(gSKHandle, "IndigoHIDMessageForKeyboardArbitrary");
  return self;
}

#pragma mark - Message construction

- (CGPoint)ratioForPoint:(CGPoint)pt {
  return CGPointMake((pt.x * _screenScale) / _pixelSize.width,
                     (pt.y * _screenScale) / _pixelSize.height);
}

// Build a single-finger touch message at a normalized ratio. direction: 1=down 2=up.
// We use Apple's IndigoHIDMessageForMouseNSEvent to obtain a correctly-initialized
// touch payload (it fills the magic fields), patch the ratio, then rebuild a
// 0x140 two-payload touch message exactly as the guest dispatcher expects.
- (TSTIndigoMessage *)buildTouchMessageAtRatio:(CGPoint)ratio direction:(int)direction sizeOut:(size_t *)sizeOut {
  CGPoint pt = ratio;
  TSTIndigoMessage *tmpl = _mouseFn ? _mouseFn(&pt, NULL, 0x32, direction, NO) : NULL;
  TSTIndigoTouch touch;
  if (tmpl) {
    memcpy(&touch, &tmpl->payload.event.touch, sizeof(TSTIndigoTouch));
  } else {
    memset(&touch, 0, sizeof(TSTIndigoTouch));
  }
  // The function does not reliably store our coordinates — patch them.
  touch.xRatio = ratio.x;
  touch.yRatio = ratio.y;

  size_t messageSize = sizeof(TSTIndigoMessage) + sizeof(TSTIndigoPayload); // 0x140
  if (sizeOut) *sizeOut = messageSize;
  size_t stride = sizeof(TSTIndigoPayload); // 0x90

  TSTIndigoMessage *message = calloc(1, messageSize);
  message->innerSize = (unsigned int)sizeof(TSTIndigoPayload);
  message->eventType = TST_INDIGO_EVENTTYPE_TOUCH;
  message->payload.field1 = 0x0000000b; // eventKind = touch
  message->payload.timestamp = mach_absolute_time();
  memcpy(&(message->payload.event.touch), &touch, sizeof(TSTIndigoTouch));

  // Duplicate the payload into the second slot and set the phase markers.
  void *src = &(message->payload);
  void *dst = (char *)src + stride;
  memcpy(dst, src, stride);
  TSTIndigoPayload *second = (TSTIndigoPayload *)dst;
  second->event.touch.field1 = 0x00000001;
  second->event.touch.field2 = 0x00000002;

  if (tmpl) free(tmpl);
  return message;
}

// Hand the bytes to the client. `freeWhenDone:YES` => the client owns/frees the copy.
- (BOOL)sendMessage:(TSTIndigoMessage *)message size:(size_t)size wait:(BOOL)wait {
  if (!_hidClient) return NO;
  void *copy = malloc(size);
  memcpy(copy, message, size);
  dispatch_semaphore_t sem = wait ? dispatch_semaphore_create(0) : NULL;
  [_hidClient sendWithMessage:copy freeWhenDone:YES completionQueue:_hidQueue completion:^(NSError *err) {
    if (sem) dispatch_semaphore_signal(sem);
  }];
  if (sem) {
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
  }
  return YES;
}

- (BOOL)touchAtPoint:(CGPoint)pt direction:(int)direction wait:(BOOL)wait {
  CGPoint r = [self ratioForPoint:pt];
  size_t sz = 0;
  TSTIndigoMessage *m = [self buildTouchMessageAtRatio:r direction:direction sizeOut:&sz];
  BOOL ok = [self sendMessage:m size:sz wait:wait];
  free(m);
  return ok;
}

// Two simultaneous touch points. Passing a non-NULL second point makes the
// SimulatorKit function emit a 3-payload multi-touch message; we patch the
// ratios at their known byte offsets (finger1, digitizer summary, finger2).
- (BOOL)twoFingerTouchAtPoint1:(CGPoint)p1 point2:(CGPoint)p2 direction:(int)direction wait:(BOOL)wait {
  if (!_mouseFn) return NO;
  CGPoint r1 = [self ratioForPoint:p1];
  CGPoint r2 = [self ratioForPoint:p2];
  CGPoint a = r1, b = r2;
  TSTIndigoMessage *msg = _mouseFn(&a, &b, 0x32, direction, NO);
  if (!msg) return NO;
  size_t size = malloc_size(msg);
  // We patch bytes up to 0x184+8; refuse to write past a shorter allocation
  // (a future SimulatorKit could return a smaller multi-touch message).
  if (size < 0x18C) { free(msg); return NO; }
  char *bytes = (char *)msg;
  memcpy(bytes + 0x3C, &r1.x, sizeof(double));   // finger 1
  memcpy(bytes + 0x44, &r1.y, sizeof(double));
  memcpy(bytes + 0xDC, &r1.x, sizeof(double));   // digitizer summary (mirrors f1)
  memcpy(bytes + 0xE4, &r1.y, sizeof(double));
  memcpy(bytes + 0x17C, &r2.x, sizeof(double));  // finger 2
  memcpy(bytes + 0x184, &r2.y, sizeof(double));
  BOOL ok = [self sendMessage:(TSTIndigoMessage *)msg size:size wait:wait];
  free(msg);
  return ok;
}

#pragma mark - Gestures

- (BOOL)tapAtX:(double)x y:(double)y error:(NSError **)error {
  if (!_hidClient) { if (error) *error = TSTMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint p = CGPointMake(x, y);
  [self touchAtPoint:p direction:TST_BUTTON_TYPE_DOWN wait:YES];
  usleep(60 * 1000);
  [self touchAtPoint:p direction:TST_BUTTON_TYPE_UP wait:YES];
  return YES;
}

- (BOOL)longPressAtX:(double)x y:(double)y duration:(double)seconds error:(NSError **)error {
  if (!_hidClient) { if (error) *error = TSTMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint p = CGPointMake(x, y);
  [self touchAtPoint:p direction:TST_BUTTON_TYPE_DOWN wait:YES];
  usleep((useconds_t)(seconds * 1e6));
  [self touchAtPoint:p direction:TST_BUTTON_TYPE_UP wait:YES];
  return YES;
}

- (BOOL)swipeFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2
          duration:(double)duration error:(NSError **)error {
  if (!_hidClient) { if (error) *error = TSTMakeError(10, @"HID client unavailable"); return NO; }
  return [self dragFromX:x1 y:y1 toX:x2 y:y2 holdDuration:0 moveDuration:duration error:error];
}

- (BOOL)dragFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2
      holdDuration:(double)holdDuration moveDuration:(double)moveDuration error:(NSError **)error {
  if (!_hidClient) { if (error) *error = TSTMakeError(10, @"HID client unavailable"); return NO; }

  CGPoint start = CGPointMake(x1, y1);
  CGPoint end = CGPointMake(x2, y2);

  // Touch down at the start.
  [self touchAtPoint:start direction:TST_BUTTON_TYPE_DOWN wait:YES];

  // Hold (drag-and-drop pickup) — re-emit the contact so recognizers fire.
  if (holdDuration > 0) {
    NSUInteger holdSteps = MAX((NSUInteger)1, (NSUInteger)(holdDuration / 0.05));
    for (NSUInteger i = 0; i < holdSteps; i++) {
      [self touchAtPoint:start direction:TST_BUTTON_TYPE_DOWN wait:NO];
      usleep(50 * 1000);
    }
  } else {
    usleep(20 * 1000);
  }

  // Interpolate from start to end. ~1 sample per frame (12ms).
  double dur = moveDuration > 0 ? moveDuration : 0.3;
  NSUInteger steps = MAX((NSUInteger)2, (NSUInteger)(dur / 0.012));
  useconds_t perStep = (useconds_t)((dur / steps) * 1e6);
  for (NSUInteger i = 1; i <= steps; i++) {
    double t = (double)i / (double)steps;
    CGPoint p = CGPointMake(start.x + (end.x - start.x) * t,
                            start.y + (end.y - start.y) * t);
    [self touchAtPoint:p direction:TST_BUTTON_TYPE_DOWN wait:NO];
    usleep(perStep);
  }

  // Release at the end.
  [self touchAtPoint:end direction:TST_BUTTON_TYPE_UP wait:YES];
  return YES;
}

// Two-finger gesture along a parameterized path. `pointsAtT` yields the two
// finger positions for t in [0,1]. Down, interpolate, up.
- (void)twoFingerGestureDuration:(double)duration
                        positions:(void (^)(double t, CGPoint *p1, CGPoint *p2))positions {
  double dur = duration > 0 ? duration : 0.4;
  NSUInteger steps = MAX((NSUInteger)4, (NSUInteger)(dur / 0.012));
  useconds_t perStep = (useconds_t)((dur / steps) * 1e6);

  CGPoint p1, p2;
  positions(0.0, &p1, &p2);
  [self twoFingerTouchAtPoint1:p1 point2:p2 direction:TST_BUTTON_TYPE_DOWN wait:YES];
  usleep(20 * 1000);
  for (NSUInteger i = 1; i <= steps; i++) {
    double t = (double)i / (double)steps;
    positions(t, &p1, &p2);
    [self twoFingerTouchAtPoint1:p1 point2:p2 direction:TST_BUTTON_TYPE_DOWN wait:NO];
    usleep(perStep);
  }
  positions(1.0, &p1, &p2);
  [self twoFingerTouchAtPoint1:p1 point2:p2 direction:TST_BUTTON_TYPE_UP wait:YES];
}

- (BOOL)pinchAtX:(double)x y:(double)y scale:(double)scale duration:(double)duration error:(NSError **)error {
  if (!_hidClient || !_mouseFn) { if (error) *error = TSTMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint center = CGPointMake(x, y);
  double base = MIN(_screenPointSize.width, _screenPointSize.height) / 4.0;
  double startGap = (scale >= 1.0) ? base : base * scale;
  double endGap   = (scale >= 1.0) ? base * scale : base;
  [self twoFingerGestureDuration:duration positions:^(double t, CGPoint *p1, CGPoint *p2) {
    double gap = startGap + (endGap - startGap) * t;
    *p1 = CGPointMake(center.x - gap / 2.0, center.y);
    *p2 = CGPointMake(center.x + gap / 2.0, center.y);
  }];
  return YES;
}

- (BOOL)rotateAtX:(double)x y:(double)y radians:(double)radians duration:(double)duration error:(NSError **)error {
  if (!_hidClient || !_mouseFn) { if (error) *error = TSTMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint center = CGPointMake(x, y);
  double radius = MIN(_screenPointSize.width, _screenPointSize.height) / 5.0;
  [self twoFingerGestureDuration:duration positions:^(double t, CGPoint *p1, CGPoint *p2) {
    double a = radians * t;
    *p1 = CGPointMake(center.x + radius * cos(a),          center.y + radius * sin(a));
    *p2 = CGPointMake(center.x + radius * cos(a + M_PI),   center.y + radius * sin(a + M_PI));
  }];
  return YES;
}

- (BOOL)isBooted {
  @try { return [_device state] == 3; } @catch (__unused id e) { return NO; }
}

#pragma mark - Keyboard

// HID usage code (USB HID Keyboard/Keypad page) + shift flag for an ASCII char.
static BOOL TSTUsageForChar(unichar c, int *usage, BOOL *shift) {
  *shift = NO;
  if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return YES; }
  if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = YES; return YES; }
  if (c >= '1' && c <= '9') { *usage = 0x1E + (c - '1'); return YES; }
  switch (c) {
    case '0': *usage = 0x27; return YES;
    case ' ': *usage = 0x2C; return YES;
    case '\n': case '\r': *usage = 0x28; return YES; // return
    case '\t': *usage = 0x2B; return YES;
    case '-': *usage = 0x2D; return YES;
    case '=': *usage = 0x2E; return YES;
    case '.': *usage = 0x37; return YES;
    case ',': *usage = 0x36; return YES;
    case '/': *usage = 0x38; return YES;
    case ';': *usage = 0x33; return YES;
    case '\'': *usage = 0x34; return YES;
    case '[': *usage = 0x2F; return YES;
    case ']': *usage = 0x30; return YES;
    case '\\': *usage = 0x31; return YES;
    case '`': *usage = 0x35; return YES;
    case '!': *usage = 0x1E; *shift = YES; return YES;
    case '@': *usage = 0x1F; *shift = YES; return YES;
    case '#': *usage = 0x20; *shift = YES; return YES;
    case '$': *usage = 0x21; *shift = YES; return YES;
    case '%': *usage = 0x22; *shift = YES; return YES;
    case '^': *usage = 0x23; *shift = YES; return YES;
    case '&': *usage = 0x24; *shift = YES; return YES;
    case '*': *usage = 0x25; *shift = YES; return YES;
    case '(': *usage = 0x26; *shift = YES; return YES;
    case ')': *usage = 0x27; *shift = YES; return YES;
    case '_': *usage = 0x2D; *shift = YES; return YES;
    case '+': *usage = 0x2E; *shift = YES; return YES;
    case '?': *usage = 0x38; *shift = YES; return YES;
    case ':': *usage = 0x33; *shift = YES; return YES;
    case '"': *usage = 0x34; *shift = YES; return YES;
    case '{': *usage = 0x2F; *shift = YES; return YES;
    case '}': *usage = 0x30; *shift = YES; return YES;
    case '|': *usage = 0x31; *shift = YES; return YES;
    case '~': *usage = 0x35; *shift = YES; return YES;
    case '<': *usage = 0x36; *shift = YES; return YES;
    case '>': *usage = 0x37; *shift = YES; return YES;
    default: return NO;
  }
}

- (BOOL)sendKeyUsage:(int)usage down:(BOOL)down {
  if (!_keyboardFn) return NO;
  TSTIndigoMessage *m = _keyboardFn(usage, down ? TST_BUTTON_TYPE_DOWN : TST_BUTTON_TYPE_UP);
  if (!m) return NO;
  size_t size = malloc_size(m);
  if (size < sizeof(TSTIndigoMessage)) { free(m); return NO; }
  BOOL ok = [self sendMessage:m size:size wait:NO];
  free(m);
  return ok;
}

- (BOOL)typeText:(NSString *)text error:(NSError **)error {
  return [self typeText:text skippedOut:NULL error:error] != nil;
}

- (nullable NSString *)typeText:(NSString *)text
                     skippedOut:(NSString * _Nullable * _Nullable)skipped
                          error:(NSError **)error {
  if (skipped) *skipped = nil;
  if (!_keyboardFn) { if (error) *error = TSTMakeError(11, @"Keyboard HID unavailable"); return nil; }
  NSMutableString *typed = [NSMutableString string];
  NSMutableString *missed = [NSMutableString string];
  // Iterate composed sequences so emoji/combining marks are reported whole
  // instead of being split into lone surrogates.
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                           options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
    int usage = 0; BOOL shift = NO;
    if (sub.length != 1 || !TSTUsageForChar([sub characterAtIndex:0], &usage, &shift)) {
      [missed appendString:sub];
      return;
    }
    if (shift) { [self sendKeyUsage:0xE1 down:YES]; usleep(6 * 1000); }
    [self sendKeyUsage:usage down:YES];
    usleep(9 * 1000);
    [self sendKeyUsage:usage down:NO];
    usleep(5 * 1000);
    if (shift) { [self sendKeyUsage:0xE1 down:NO]; usleep(6 * 1000); }
    [typed appendString:sub];
  }];
  if (skipped && missed.length) *skipped = [missed copy];
  return [typed copy];
}

- (BOOL)pressKeyUsage:(int)usage error:(NSError **)error {
  return [self pressKeyUsage:usage modifiers:0 error:error];
}

- (BOOL)pressKeyUsage:(int)usage modifiers:(int)modifierMask error:(NSError **)error {
  if (!_keyboardFn) { if (error) *error = TSTMakeError(11, @"Keyboard HID unavailable"); return NO; }
  // Bit 0 ctrl, 1 shift, 2 alt, 3 cmd — left-hand usages on the keyboard page.
  static const int kModUsages[4] = {0xE0, 0xE1, 0xE2, 0xE3};
  int held[4]; int n = 0;
  for (int i = 0; i < 4; i++) {
    if (modifierMask & (1 << i)) {
      held[n++] = kModUsages[i];
      [self sendKeyUsage:kModUsages[i] down:YES];
      usleep(6 * 1000);
    }
  }
  [self sendKeyUsage:usage down:YES];
  usleep(9 * 1000);
  [self sendKeyUsage:usage down:NO];
  usleep(5 * 1000);
  for (int i = n - 1; i >= 0; i--) {   // release in reverse order
    [self sendKeyUsage:held[i] down:NO];
    usleep(6 * 1000);
  }
  return YES;
}

#pragma mark - Hardware buttons

// A hardware button rides the same envelope as a keyboard key: eventType 1
// (button), payload eventKind 2, and a TSTIndigoButton whose eventSource names
// the button and whose eventTarget is 0x33 (hardware) rather than 0x64
// (keyboard). We take a keyboard message as the template so Apple's own code
// fills the mach header / magic fields, then repoint it at the hardware target.
- (BOOL)sendButtonSource:(unsigned int)source down:(BOOL)down {
  if (!_keyboardFn) return NO;
  int dir = down ? TST_BUTTON_TYPE_DOWN : TST_BUTTON_TYPE_UP;
  TSTIndigoMessage *m = _keyboardFn(0, dir);
  if (!m) return NO;
  size_t size = malloc_size(m);
  if (size < sizeof(TSTIndigoMessage)) { free(m); return NO; }
  m->eventType = TST_INDIGO_EVENTTYPE_BUTTON;
  m->payload.field1 = 2;  // eventKind = button
  m->payload.timestamp = mach_absolute_time();
  m->payload.event.button.eventSource = source;
  m->payload.event.button.eventType = (unsigned int)dir;
  m->payload.event.button.eventTarget = TST_BUTTON_TARGET_HARDWARE;
  m->payload.event.button.keyCode = 0;
  BOOL ok = [self sendMessage:m size:size wait:NO];
  free(m);
  return ok;
}

- (BOOL)pressButton:(NSString *)name error:(NSError **)error {
  if (!_keyboardFn) { if (error) *error = TSTMakeError(11, @"Keyboard HID unavailable"); return NO; }
  static NSDictionary<NSString *, NSNumber *> *sources;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sources = @{
      @"home":      @(TST_BUTTON_SOURCE_HOME),
      @"lock":      @(TST_BUTTON_SOURCE_LOCK),
      @"power":     @(TST_BUTTON_SOURCE_LOCK),
      @"side":      @(TST_BUTTON_SOURCE_SIDE),
      @"siri":      @(TST_BUTTON_SOURCE_SIRI),
      @"apple-pay": @(TST_BUTTON_SOURCE_APPLE_PAY),
      @"applepay":  @(TST_BUTTON_SOURCE_APPLE_PAY),
    };
  });
  NSNumber *src = sources[name.lowercaseString];
  if (!src) {
    if (error) *error = TSTMakeError(12, [NSString stringWithFormat:
      @"unknown button '%@' (want home, lock, side, siri or apple-pay)", name]);
    return NO;
  }
  unsigned int source = src.unsignedIntValue;
  if (![self sendButtonSource:source down:YES]) {
    if (error) *error = TSTMakeError(13, @"could not build button event");
    return NO;
  }
  usleep(50 * 1000);
  [self sendButtonSource:source down:NO];
  return YES;
}

#pragma mark - Accessibility

- (nullable NSArray<NSDictionary<NSString *, id> *> *)accessibilityTreeWithError:(NSError **)error {
  if (![[self class] loadFrameworks:error]) return nil;
  __block NSArray *result = nil;
  __block NSError *err = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  // AXPTranslator delegation must not run on the main queue.
  dispatch_async(_axQueue, ^{
    result = [self walkAccessibilityTree:&err];
    dispatch_semaphore_signal(sem);
  });
  // Never block forever: a wedged simulator would hang the daemon for good.
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, TSTAXWaitSeconds * NSEC_PER_SEC)) != 0) {
    if (error) *error = TSTMakeError(24, @"accessibility walk timed out — simulator unresponsive?");
    return nil;
  }
  if (!result && error) *error = err;
  return result;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)walkAccessibilityTree:(NSError **)error {
  TSTAXDispatcher *disp = [TSTAXDispatcher shared];
  id translator = [disp translator];
  if (!translator) {
    if (error) *error = TSTMakeError(20, @"AXPTranslator unavailable");
    return nil;
  }
  [self beginWalk];
  NSString *token = [NSUUID UUID].UUIDString;
  [disp registerToken:token device:_device];

  id root = [(id<TSTAXPTranslator>)translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
  if (!root) {
    [disp unregisterToken:token];
    if (error) *error = TSTMakeError(21, @"No frontmost application (accessibility)");
    return nil;
  }
  [(id<TSTAXPTranslationObject>)root setBridgeDelegateToken:token];

  id element = [(id<TSTAXPTranslator>)translator macPlatformElementFromTranslation:root];
  if (!element) {
    [disp unregisterToken:token];
    if (error) *error = TSTMakeError(22, @"Could not translate frontmost element");
    return nil;
  }
  id tr = [(id<TSTAXPElement>)element translation];
  if (tr) [(id<TSTAXPTranslationObject>)tr setBridgeDelegateToken:token];

  // SpringBoard remediation: a zero-frame root indicates a stale accessibility
  // server (common on long-lived iOS 26 sims). Retry once with a fresh token.
  if (CGRectEqualToRect([(id<NSAccessibility>)element accessibilityFrame], CGRectZero)) {
    [disp unregisterToken:token];
    usleep(400 * 1000);
    NSString *t2 = [NSUUID UUID].UUIDString;
    [disp registerToken:t2 device:_device];
    id root2 = [(id<TSTAXPTranslator>)translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:t2];
    if (root2) {
      [(id<TSTAXPTranslationObject>)root2 setBridgeDelegateToken:t2];
      id el2 = [(id<TSTAXPTranslator>)translator macPlatformElementFromTranslation:root2];
      if (el2) {
        id tr2 = [(id<TSTAXPElement>)el2 translation];
        if (tr2) [(id<TSTAXPTranslationObject>)tr2 setBridgeDelegateToken:t2];
        element = el2; token = t2;
      }
    }
  }

  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  [self serializeElement:element token:token depth:0 into:out];
  [disp unregisterToken:token];
  // Tell the caller the tree is partial rather than silently reporting a
  // half-read screen as the whole screen.
  if (_walkTruncated) {
    [out addObject:@{@"role": @"AXTruncated", @"label": @"tree truncated (deadline)"}];
  }
  return out;
}

#pragma mark - Walk deadline

// Arm the per-walk deadline and clear the bridge's timeout flag. Called on the
// _axQueue at the start of every tree walk / element search.
- (void)beginWalk {
  _walkDeadline = CFAbsoluteTimeGetCurrent() + TSTAXWalkDeadline;
  _walkTruncated = NO;
  [[TSTAXDispatcher shared] resetRequestTimeout];
}

// YES once we must stop descending: either the wall-clock deadline passed or a
// bridged AX read timed out (each further read would cost another 10 s).
- (BOOL)walkShouldStop {
  if (_walkTruncated) return YES;
  if (CFAbsoluteTimeGetCurrent() > _walkDeadline) { _walkTruncated = YES; return YES; }
  if ([TSTAXDispatcher shared].lastRequestTimedOut) { _walkTruncated = YES; return YES; }
  return NO;
}

#pragma mark - Set value (universal text)

- (BOOL)setAccessibilityValue:(NSString *)value forIdentifier:(NSString *)identifier label:(NSString *)label error:(NSError **)error {
  if (![[self class] loadFrameworks:error]) return NO;
  __block BOOL ok = NO;
  __block NSError *err = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(_axQueue, ^{
    TSTAXDispatcher *disp = [TSTAXDispatcher shared];
    id translator = [disp translator];
    if (!translator) { err = TSTMakeError(20, @"AXPTranslator unavailable"); dispatch_semaphore_signal(sem); return; }
    [self beginWalk];
    NSString *token = [NSUUID UUID].UUIDString;
    [disp registerToken:token device:self->_device];
    id root = [(id<TSTAXPTranslator>)translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
    if (root) {
      [(id<TSTAXPTranslationObject>)root setBridgeDelegateToken:token];
      id element = [(id<TSTAXPTranslator>)translator macPlatformElementFromTranslation:root];
      if (element) {
        id tr = [(id<TSTAXPElement>)element translation];
        if (tr) [(id<TSTAXPTranslationObject>)tr setBridgeDelegateToken:token];
        id match = [self findElement:element token:token identifier:identifier label:label depth:0];
        if (match) {
          [(id<TSTAXPElement>)match setAccessibilityValue:value];
          ok = YES;
        } else {
          err = self->_walkTruncated
            ? TSTMakeError(24, @"accessibility walk timed out — simulator unresponsive?")
            : TSTMakeError(23, @"element not found for setValue");
        }
      }
    }
    [disp unregisterToken:token];
    dispatch_semaphore_signal(sem);
  });
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, TSTAXWaitSeconds * NSEC_PER_SEC)) != 0) {
    if (error) *error = TSTMakeError(24, @"accessibility walk timed out — simulator unresponsive?");
    return NO;
  }
  if (!ok && error) *error = err;
  return ok;
}

- (id)findElement:(id)element token:(NSString *)token identifier:(NSString *)identifier label:(NSString *)label depth:(int)depth {
  if (depth > 60) return nil;
  if ([self walkShouldStop]) return nil;
  id<NSAccessibility> ax = (id<NSAccessibility>)element;
  id tr = [(id<TSTAXPElement>)element translation];
  if (tr) [(id<TSTAXPTranslationObject>)tr setBridgeDelegateToken:token];
  NSString *eid = [ax accessibilityIdentifier];
  NSString *elabel = [ax accessibilityLabel];
  if ((identifier && eid && [eid isEqualToString:identifier]) ||
      (label && elabel && [elabel isEqualToString:label])) {
    return element;
  }
  for (id child in [ax accessibilityChildren]) {
    id m = [self findElement:child token:token identifier:identifier label:label depth:depth + 1];
    if (m) return m;
  }
  return nil;
}

#pragma mark - Screenshot + OCR (works without app accessibility)

// Copy the current framebuffer as a CGImage (caller releases). NULL on failure.
- (CGImageRef)copyScreenCGImage CF_RETURNS_RETAINED {
  id ioClient = [_device io];
  if (!ioClient) return NULL;
  NSArray *ports = nil;
  @try { ports = [(id<TSTIOClient>)ioClient ioPorts]; } @catch (__unused id e) { return NULL; }
  IOSurfaceRef surface = NULL;
  for (id port in ports) {
    id desc = nil;
    if ([port respondsToSelector:@selector(descriptor)]) {
      @try { desc = [(id<TSTIOPort>)port descriptor]; } @catch (__unused id e) {}
    }
    if (!desc) continue;
    if ([desc respondsToSelector:@selector(framebufferSurface)]) {
      @try { surface = [(id<TSTDisplaySurface>)desc framebufferSurface]; } @catch (__unused id e) {}
    }
    if (!surface && [desc respondsToSelector:@selector(ioSurface)]) {
      @try { surface = [(id<TSTDisplaySurface>)desc ioSurface]; } @catch (__unused id e) {}
    }
    if (surface) break;
  }
  if (!surface) return NULL;
  IOSurfaceIncrementUseCount(surface);
  CIImage *ci = [CIImage imageWithIOSurface:surface];
  CGImageRef cg = NULL;
  if (ci) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    cg = [ctx createCGImage:ci fromRect:ci.extent];
  }
  IOSurfaceDecrementUseCount(surface);
  return cg;
}

- (BOOL)screenshotToPath:(NSString *)path error:(NSError **)error {
  CGImageRef cg = [self copyScreenCGImage];
  if (!cg) { if (error) *error = TSTMakeError(30, @"could not capture framebuffer"); return NO; }
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
  BOOL ok = NO;
  if (dest) {
    CGImageDestinationAddImage(dest, cg, NULL);
    ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CGImageRelease(cg);
  if (!ok && error) *error = TSTMakeError(31, @"could not write PNG");
  return ok;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)recognizeTextWithError:(NSError **)error {
  CGImageRef cg = [self copyScreenCGImage];
  if (!cg) { if (error) *error = TSTMakeError(30, @"could not capture framebuffer"); return nil; }
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
  VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
  req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  req.usesLanguageCorrection = YES;
  NSError *e = nil;
  BOOL ran = [handler performRequests:@[req] error:&e];
  CGImageRelease(cg);
  if (!ran) { if (error) *error = e ?: TSTMakeError(32, @"OCR failed"); return nil; }

  double W = _screenPointSize.width, H = _screenPointSize.height;
  NSMutableArray *out = [NSMutableArray array];
  for (VNRecognizedTextObservation *obs in req.results) {
    VNRecognizedText *t = [[obs topCandidates:1] firstObject];
    if (!t || t.string.length == 0) continue;
    CGRect bb = obs.boundingBox; // normalized, bottom-left origin
    double x = bb.origin.x * W;
    double y = (1.0 - bb.origin.y - bb.size.height) * H; // flip to top-left
    [out addObject:@{
      @"text": t.string,
      @"x": @(x), @"y": @(y),
      @"w": @(bb.size.width * W), @"h": @(bb.size.height * H),
      @"conf": @(t.confidence),
    }];
  }
  return out;
}

- (void)serializeElement:(id)element token:(NSString *)token depth:(int)depth into:(NSMutableArray *)out {
  if (depth > 60 || out.count > 3000) return;
  // Bail out of a hung/slow tree instead of walking it to the end.
  if ([self walkShouldStop]) return;
  id<NSAccessibility> ax = (id<NSAccessibility>)element;
  id<TSTAXPElement> axp = (id<TSTAXPElement>)element;

  id tr = [axp translation];
  if (tr) [(id<TSTAXPTranslationObject>)tr setBridgeDelegateToken:token];

  NSRect frame = [ax accessibilityFrame];
  NSString *role = [ax accessibilityRole];
  NSString *label = [ax accessibilityLabel];
  NSString *ident = [ax accessibilityIdentifier];
  id valueObj = [ax accessibilityValue];
  NSString *value = nil;
  if ([valueObj isKindOfClass:NSString.class]) value = valueObj;
  else if ([valueObj isKindOfClass:NSNumber.class]) value = [valueObj stringValue];

  BOOL enabled = YES;
  @try { enabled = [ax isAccessibilityEnabled]; } @catch (__unused id e) {}

  uint64_t traits = 0;
  id traitsVal = [axp accessibilityAttributeValue:@"AXTraits"];
  if ([traitsVal isKindOfClass:NSNumber.class]) traits = [traitsVal unsignedLongLongValue];

  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"role"] = role ?: @"";
  if (label.length) d[@"label"] = label;
  if (ident.length) d[@"id"] = ident;
  if (value.length) d[@"value"] = value;
  d[@"x"] = @(frame.origin.x);
  d[@"y"] = @(frame.origin.y);
  d[@"w"] = @(frame.size.width);
  d[@"h"] = @(frame.size.height);
  d[@"enabled"] = @(enabled);
  d[@"traits"] = @(traits);
  d[@"depth"] = @(depth);
  [out addObject:d];

  NSArray *children = [ax accessibilityChildren];
  for (id child in children) {
    [self serializeElement:child token:token depth:depth + 1 into:out];
  }
}

+ (NSString *)layoutDescription {
  BOOL payloadOK = (sizeof(TSTIndigoPayload) == 0x90);
  BOOL messageOK = (sizeof(TSTIndigoMessage) == 0xB0);
  BOOL touchOK   = (sizeof(TSTIndigoMessage) + sizeof(TSTIndigoPayload) == 0x140);
  // Button payload sits at message+0x30, same slot the touch payload starts in.
  BOOL buttonOK  = (offsetof(TSTIndigoMessage, payload.event.button.eventSource) == 0x30 &&
                    offsetof(TSTIndigoMessage, payload.event.button.eventType) == 0x34 &&
                    offsetof(TSTIndigoMessage, payload.event.button.eventTarget) == 0x38 &&
                    offsetof(TSTIndigoMessage, payload.event.button.keyCode) == 0x3c);
  return [NSString stringWithFormat:
    @"Indigo layout: payload=0x%zx(%@) message=0x%zx(%@) touchMsg=0x%zx(%@) touch=0x%zx button=0x%zx(%@)",
    sizeof(TSTIndigoPayload), payloadOK ? @"OK" : @"BAD",
    sizeof(TSTIndigoMessage), messageOK ? @"OK" : @"BAD",
    sizeof(TSTIndigoMessage) + sizeof(TSTIndigoPayload), touchOK ? @"OK" : @"BAD",
    sizeof(TSTIndigoTouch),
    sizeof(TSTIndigoButton), buttonOK ? @"OK" : @"BAD"];
}

@end
