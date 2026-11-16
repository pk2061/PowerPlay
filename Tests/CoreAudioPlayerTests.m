#import <Foundation/Foundation.h>
#import <string.h>
#import "CoreAudioPlayer.h"

@interface TestAudioPlayer : CoreAudioPlayer
- (id)initForTest;
- (void)appendTestBytes:(NSUInteger)length;
- (NSUInteger)queuedLength;
- (void)setTestPlaying:(BOOL)playing;
@end

@implementation TestAudioPlayer
- (id)initForTest {
    self = [super init];
    if (self != nil) {
        memset(&streamFormat, 0, sizeof(streamFormat));
        streamFormat.mSampleRate = 1000.0;
        streamFormat.mBytesPerFrame = 4;
        streamFormat.mBitsPerChannel = 16;
        queuedAudio = [[NSMutableData alloc] init];
        isPlaying = YES;
        bufferingAudio = YES;
        volume = 1.0f;
    }
    return self;
}
- (void)appendTestBytes:(NSUInteger)length {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    memset([data mutableBytes], 0x7f, length);
    [queuedAudio appendData:data];
}
- (NSUInteger)queuedLength { return [queuedAudio length]; }
- (void)setTestPlaying:(BOOL)playing { isPlaying = playing; }
@end

static BOOL Check(BOOL condition, NSString *message) {
    if (!condition) NSLog(@"FAIL: %@", message);
    return condition;
}

static BOOL Render(TestAudioPlayer *player, NSUInteger expectedAudioBytes) {
    unsigned char output[400];
    memset(output, 0xff, sizeof(output));
    AudioBufferList buffers;
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = 2;
    buffers.mBuffers[0].mDataByteSize = sizeof(output);
    buffers.mBuffers[0].mData = output;
    if ([player renderAudioToBufferList:&buffers frames:100] != noErr) return NO;
    NSUInteger index;
    for (index = 0; index < sizeof(output); index++) {
        if (output[index] != (index < expectedAudioBytes ? 0x7f : 0)) return NO;
    }
    return YES;
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TestAudioPlayer *player = [[TestAudioPlayer alloc] initForTest];
    BOOL passed = YES;
    [player appendTestBytes:800];
    passed &= Check(Render(player, 0) && [player queuedLength] == 800,
                    @"startup must retain audio until the prebuffer is full");
    [player appendTestBytes:200];
    passed &= Check(Render(player, 400) && [player queuedLength] == 600,
                    @"audio should play once the prebuffer is full");
    passed &= Check(Render(player, 400) && [player queuedLength] == 200,
                    @"buffered audio should continue playing");
    passed &= Check(Render(player, 200) && [player queuedLength] == 0,
                    @"an underrun should play remaining audio and fill silence");
    [player appendTestBytes:600];
    passed &= Check(Render(player, 0) && [player queuedLength] == 600,
                    @"an underrun should rebuffer before playing again");
    [player appendTestBytes:400];
    passed &= Check(Render(player, 400) && [player queuedLength] == 600,
                    @"playback should resume when the prebuffer refills");
    [player setTestPlaying:NO];
    passed &= Check(Render(player, 0) && [player queuedLength] == 600,
                    @"stopped output must not consume queued audio");
    [player release];
    NSLog(@"CoreAudio buffering tests %@", passed ? @"passed" : @"failed");
    [pool drain];
    return passed ? 0 : 1;
}