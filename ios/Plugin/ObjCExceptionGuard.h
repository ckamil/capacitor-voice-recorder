#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C exception handling into Swift. Swift's `do/catch` only catches
/// Swift `Error`s — it cannot catch Objective-C `NSException`. AVAudioEngine (`start()`,
/// `installTap`) can raise a CoreAudio `NSException` when the shared audio session is held
/// by another process (e.g. Zoom/Teams screen-share via ReplayKit), which would otherwise
/// crash the whole app. Wrap those calls in `tryBlock:error:` so the exception surfaces as
/// a Swift-catchable `NSError` and the caller can fall back gracefully.
@interface ObjCExceptionGuard : NSObject

/// Runs `block`. Returns YES if it completed normally, NO if it raised an NSException
/// (in which case `error` is populated with the exception name/reason).
/// NS_SWIFT_NOTHROW keeps the explicit BOOL-return + error out-param signature in Swift
/// (otherwise the trailing NSError** would be imported as a throwing method).
/// NS_SWIFT_NAME pins the Swift name — the importer otherwise strips the "Block" suffix
/// and exposes it as `try(_:error:)`, which is diagnosed as an obsoleted Swift 3 rename.
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NOTHROW NS_SWIFT_NAME(tryBlock(_:error:));

@end

NS_ASSUME_NONNULL_END
