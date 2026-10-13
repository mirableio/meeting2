#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Device changes can invalidate a format between reading it and installing the tap.
// Swift cannot catch Objective-C exceptions; expose this one operation as a normal
// throwing method so MicCapture's bounded recovery can retry without killing the app.
@interface Meeting2AudioTapInstaller : NSObject
+ (BOOL)installOnNode:(AVAudioNode *)node
                 bus:(AVAudioNodeBus)bus
          bufferSize:(AVAudioFrameCount)bufferSize
              format:(AVAudioFormat *)format
               block:(AVAudioNodeTapBlock)block
               error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
