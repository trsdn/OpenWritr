#import "include/ObjCExceptionCatcher.h"

BOOL ObjCTryCatch(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:exception.name
                                         code:-1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"Unknown ObjC exception"
            }];
        }
        return NO;
    }
}
