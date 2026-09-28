#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised as an error, or nil when it raised none.
///
/// AVFoundation reports a broken precondition, such as an input added twice to a capture session, by raising an
/// NSException. Swift cannot catch one, so without this the process ends.
NSError *_Nullable HarkCatchException(NS_NOESCAPE void (^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
