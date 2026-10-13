#import "Meeting2AudioSupport.h"

@implementation Meeting2AudioTapInstaller
+ (BOOL)installOnNode:(AVAudioNode *)node
                 bus:(AVAudioNodeBus)bus
          bufferSize:(AVAudioFrameCount)bufferSize
              format:(AVAudioFormat *)format
               block:(AVAudioNodeTapBlock)block
               error:(NSError **)error {
    // Keep the exception boundary around tap installation only. The older API
    // raises NSException for an invalid graph/format, including during a route
    // transition; even the error-returning API can still raise graph assertions.
    @try {
        if (@available(macOS 27.0, *)) {
            return [node installTapOnBus:bus bufferSize:bufferSize format:format error:error block:block];
        }
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"com.mirable.Meeting2.AudioTap"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}
@end
