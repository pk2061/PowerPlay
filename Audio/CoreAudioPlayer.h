#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@interface CoreAudioPlayer : NSObject {
    AudioQueueRef audioQueue;
    AudioStreamBasicDescription streamFormat;
    BOOL isPlaying;
    NSMutableData *queuedAudio;
    UInt32 queueBufferBytes;
    UInt32 queueBufferCount;
    float targetLatencySeconds;
}

- (id)initWithFormat:(AudioStreamBasicDescription)format;
- (UInt32)recommendedBufferSize;
- (void)prepareQueueBuffers;
- (void)refillOutputBuffer:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer;
- (void)start;
- (void)stop;
- (void)enqueuePCMData:(NSData *)pcmData;
- (BOOL)isPlaying;

@end
