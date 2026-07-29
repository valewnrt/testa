// TestaEngine.h — public surface consumed by Swift.
//
// A TSTSimulator wraps a booted iOS Simulator (SimDevice) and exposes
// HID injection. Coordinates are in POINTS (the same space as accessibility
// frames), origin top-left.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSTSimulator : NSObject

@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) CGSize screenPointSize; // logical points
@property (nonatomic, readonly) CGFloat screenScale;    // 2.0 / 3.0

/// First booted simulator, or nil with error if none / framework load failed.
+ (nullable instancetype)bootedSimulatorWithError:(NSError **)error;

/// Specific simulator by UDID (must be booted).
+ (nullable instancetype)simulatorWithUDID:(NSString *)udid error:(NSError **)error
    NS_SWIFT_NAME(withUDID(_:));

// --- HID gestures (points, top-left origin) ---

- (BOOL)tapAtX:(double)x y:(double)y error:(NSError **)error
    NS_SWIFT_NAME(tap(x:y:));

- (BOOL)longPressAtX:(double)x y:(double)y duration:(double)seconds error:(NSError **)error
    NS_SWIFT_NAME(longPress(x:y:duration:));

/// Linear swipe/scroll from (x1,y1) to (x2,y2) over `duration` seconds.
- (BOOL)swipeFromX:(double)x1 y:(double)y1
               toX:(double)x2 y:(double)y2
          duration:(double)duration
             error:(NSError **)error
    NS_SWIFT_NAME(swipe(x1:y1:x2:y2:duration:));

/// Drag-and-drop: press, hold for `holdDuration` (pickup), move to target, release.
- (BOOL)dragFromX:(double)x1 y:(double)y1
              toX:(double)x2 y:(double)y2
      holdDuration:(double)holdDuration
     moveDuration:(double)moveDuration
            error:(NSError **)error
    NS_SWIFT_NAME(drag(x1:y1:x2:y2:hold:move:));

/// Whether the bound simulator is still booted (re-reads device state).
- (BOOL)isBooted;

/// Type a string via the hardware keyboard (the focused field receives it).
- (BOOL)typeText:(NSString *)text error:(NSError **)error NS_SWIFT_NAME(type(_:));

/// Type a string, reporting what the HID keyboard could not represent.
/// Returns the text actually typed (nil only on failure, with `error` set);
/// `skipped` receives every character that has no US-keyboard usage code
/// (emoji, accents, CJK …), or nil when everything was typed. Use
/// -setAccessibilityValue:forIdentifier:label:error: for those.
- (nullable NSString *)typeText:(NSString *)text
                     skippedOut:(NSString * _Nullable * _Nullable)skipped
                          error:(NSError **)error
    NS_SWIFT_NAME(type(_:skipped:));

/// Press a single HID usage key (e.g. 0x2A backspace, 0x28 return).
- (BOOL)pressKeyUsage:(int)usage error:(NSError **)error NS_SWIFT_NAME(pressKey(usage:));

/// Press a key with modifiers held down (Cmd+A, Cmd+V, Ctrl+C …).
/// `modifierMask` bits: 0 = left-ctrl, 1 = left-shift, 2 = left-alt, 3 = left-cmd.
/// Modifiers go down in that order and are released in reverse.
- (BOOL)pressKeyUsage:(int)usage modifiers:(int)modifierMask error:(NSError **)error
    NS_SWIFT_NAME(pressKey(usage:modifiers:));

/// Press a hardware button: @"home", @"lock" (aka @"power"/@"side"), @"siri"
/// or @"apple-pay". Down, 50 ms, up.
- (BOOL)pressButton:(NSString *)name error:(NSError **)error
    NS_SWIFT_NAME(pressButton(_:));

/// Pinch at center (x,y). scale>1 zooms in, scale<1 zooms out.
- (BOOL)pinchAtX:(double)x y:(double)y scale:(double)scale duration:(double)duration error:(NSError **)error
    NS_SWIFT_NAME(pinch(x:y:scale:duration:));

/// Two-finger rotation at center (x,y) by `radians` (positive = clockwise).
- (BOOL)rotateAtX:(double)x y:(double)y radians:(double)radians duration:(double)duration error:(NSError **)error
    NS_SWIFT_NAME(rotate(x:y:radians:duration:));

/// Flattened accessibility tree of the frontmost app. Each element dict has:
/// role, label, id, value, x, y, w, h, enabled, traits, depth.
/// The walk is bounded (25 s, and it aborts as soon as a bridged read times
/// out); if it was cut short, a final `{role: AXTruncated}` marker is appended.
/// Returns nil with an error if the simulator never answered at all.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)accessibilityTreeWithError:(NSError **)error
    NS_SWIFT_NAME(accessibilityTree());

/// In-process screenshot (framebuffer IOSurface -> PNG). No subprocess.
- (BOOL)screenshotToPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(screenshot(toPath:));

/// On-device OCR (Apple Vision) of the current screen. Each dict: text, x, y, w,
/// h (points, top-left), conf. Works on ANY app — no accessibility needed.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)recognizeTextWithError:(NSError **)error
    NS_SWIFT_NAME(recognizeText());

/// Set a field's value directly (any unicode) by matching its identifier/label.
- (BOOL)setAccessibilityValue:(NSString *)value
                forIdentifier:(nullable NSString *)identifier
                        label:(nullable NSString *)label
                        error:(NSError **)error
    NS_SWIFT_NAME(setValue(_:identifier:label:));

/// Diagnostic: verifies the Indigo struct layout matches the wire format.
+ (NSString *)layoutDescription;

@end

NS_ASSUME_NONNULL_END
