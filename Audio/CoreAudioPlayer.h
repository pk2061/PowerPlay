#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreServices/CoreServices.h>

@interface CoreAudioPlayer : NSObject {
    AudioUnit outputUnit;
    AudioStreamBasicDescription streamFormat;
    BOOL isPlaying;
    float volume;
    NSMutableData *queuedAudio;
}

- (id)initWithAudioFormat:(AudioStreamBasicDescription *)format;
- (OSStatus)renderAudioToBufferList:(AudioBufferList *)bufferList frames:(UInt32)frameCount;
- (void)start;
- (void)stop;
- (void)setVolume:(float)volume;
- (void)enqueuePCMData:(NSData *)pcmData;
- (BOOL)isPlaying;

@end
