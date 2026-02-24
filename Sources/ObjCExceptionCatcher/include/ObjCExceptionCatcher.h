#import <Foundation/Foundation.h>

/// Catches ObjC exceptions and returns them as NSError.
/// Returns YES on success, NO if an exception was caught.
FOUNDATION_EXPORT BOOL ObjCTryCatch(void (NS_NOESCAPE ^_Nonnull block)(void),
                                     NSError *_Nullable *_Nullable error);
