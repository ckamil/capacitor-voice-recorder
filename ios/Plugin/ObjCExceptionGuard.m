#import "ObjCExceptionGuard.h"

@implementation ObjCExceptionGuard

+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"VoiceRecorderAudioEngine"
                                         code:-1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                         @"exceptionName": exception.name
                                     }];
        }
        return NO;
    }
}

@end
