//
//  PickyObjCExceptionTrap.h
//  Picky
//
//  Bridges Objective-C `@try/@catch` to Swift. AVFAudio APIs (e.g.
//  `-[AVAudioNode installTapOnBus:bufferSize:format:block:]`) raise
//  NSException on format/route mismatches, which Swift `try` cannot catch —
//  the unhandled exception then terminates the app. Use
//  `PickyTrapObjCException` to convert such throws into a Swift `Error`.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Runs `block` inside an Objective-C `@try/@catch`. Returns YES on success.
 If the block raises an NSException, returns NO and (when non-NULL)
 populates `*error` with an NSError whose userInfo carries the exception's
 `name`, `reason`, and `callStackSymbols`.

 The block runs synchronously on the current thread/queue. Do not perform
 long-running work inside it — this is intended only to wrap a single
 throwing call (e.g. `installTapOnBus:...`).
 */
BOOL PickyTrapObjCException(NS_NOESCAPE void (^block)(void),
                            NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
