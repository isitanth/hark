#import "HarkObjC.h"

NSError *_Nullable HarkCatchException(NS_NOESCAPE void (^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *description = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"HarkObjCException"
                                   code:0
                               userInfo:@{NSLocalizedDescriptionKey : description, @"name" : exception.name}];
    }
}
