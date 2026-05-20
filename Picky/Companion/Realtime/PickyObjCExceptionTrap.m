//
//  PickyObjCExceptionTrap.m
//  Picky
//

#import "PickyObjCExceptionTrap.h"

NSString *const PickyObjCExceptionErrorDomain = @"com.jonghakseo.picky.objc-exception";

BOOL PickyTrapObjCException(NS_NOESCAPE void (^block)(void),
                            NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo =
                [NSMutableDictionary dictionaryWithCapacity:4];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            if (exception.name) userInfo[@"NSExceptionName"] = exception.name;
            if (exception.reason) userInfo[@"NSExceptionReason"] = exception.reason;
            if (exception.callStackSymbols) {
                userInfo[@"NSExceptionCallStackSymbols"] = exception.callStackSymbols;
            }
            *error = [NSError errorWithDomain:PickyObjCExceptionErrorDomain
                                         code:0
                                     userInfo:userInfo];
        }
        return NO;
    }
}
