#import "CoreAudioPlayer.h"

static void AQOutputCallback(void *inUserData, AudioQueueRef inAQ,
                            AudioQueueBufferRef inBuffer) {
    CoreAudioPlayer *player = (CoreAudioPlayer *)inUserData;
    if (player == nil) {
        return;
    }

    if (![player isPlaying]) {
        AudioQueueFreeBuffer(inAQ, inBuffer);
        return;
    }

    [player refillOutputBuffer:inAQ buffer:inBuffer];
}

@implementation CoreAudioPlayer

- (UInt32)recommendedBufferSize {
    if (streamFormat.mSampleRate <= 0.0) {
        return 4096;
    }

    const UInt32 bytesPerSample = (streamFormat.mBitsPerChannel * streamFormat.mChannelsPerFrame) / 8;
    const UInt32 framesPerBuffer = (UInt32)(streamFormat.mSampleRate * targetLatencySeconds / 1.0);
    UInt32 bytesPerBuffer = framesPerBuffer * bytesPerSample;
    if (bytesPerBuffer < 2048) {
        bytesPerBuffer = 2048;
    }
    if (bytesPerBuffer > 16384) {
        bytesPerBuffer = 16384;
    }
    return bytesPerBuffer;
}

- (void)prepareQueueBuffers {
    if (audioQueue == NULL || queueBufferBytes == 0) {
        return;
    }

    for (UInt32 i = 0; i < queueBufferCount; i++) {
        AudioQueueBufferRef buffer = NULL;
        OSStatus status = AudioQueueAllocateBuffer(audioQueue, queueBufferBytes, &buffer);
        if (status == noErr && buffer != NULL) {
            memset(buffer->mAudioData, 0, queueBufferBytes);
            buffer->mAudioDataByteSize = queueBufferBytes;
            AudioQueueEnqueueBuffer(audioQueue, buffer, 0, NULL);
        }
    }
}

- (void)refillOutputBuffer:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer {
    if (buffer == NULL || queue == NULL) {
        return;
    }

    UInt32 bytesAvailable = (UInt32)[queuedAudio length];
    UInt32 bytesToCopy = 0;
    if (bytesAvailable > 0) {
        bytesToCopy = MIN((UInt32)buffer->mAudioDataBytesCapacity, bytesAvailable);
        memcpy(buffer->mAudioData, [queuedAudio bytes], bytesToCopy);
        [queuedAudio replaceBytesInRange:NSMakeRange(0, bytesToCopy) withBytes:NULL length:0];
    }

    if (bytesToCopy < buffer->mAudioDataBytesCapacity) {
        memset(((unsigned char *)buffer->mAudioData) + bytesToCopy, 0, buffer->mAudioDataBytesCapacity - bytesToCopy);
    }
    buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

- (id)initWithFormat:(AudioStreamBasicDescription)format {
    self = [super init];
    if (self != nil) {
        streamFormat = format;
        audioQueue = NULL;
        isPlaying = NO;
        queuedAudio = [[NSMutableData alloc] init];
        queueBufferCount = 3;
        targetLatencySeconds = 0.05f;
        queueBufferBytes = 0;

        OSStatus status = AudioQueueNewOutput(&streamFormat, AQOutputCallback, self,
                                              NULL, NULL, 0, &audioQueue);
        if (status != noErr || audioQueue == NULL) {
            NSLog(@"CoreAudio: failed to create output queue (%d)", (int)status);
        } else {
            queueBufferBytes = [self recommendedBufferSize];
            [self prepareQueueBuffers];
            AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1.0f);
        }
    }
    return self;
}

- (void)dealloc {
    if (audioQueue != NULL) {
        AudioQueueStop(audioQueue, YES);
        AudioQueueDispose(audioQueue, YES);
        audioQueue = NULL;
    }
    [queuedAudio release];
    [super dealloc];
}

- (void)start {
    if (audioQueue == NULL) {
        return;
    }

    if (!isPlaying) {
        AudioQueueStart(audioQueue, NULL);
        isPlaying = YES;
    }
}

- (void)stop {
    if (audioQueue == NULL) {
        return;
    }

    AudioQueueStop(audioQueue, YES);
    isPlaying = NO;
    [queuedAudio setLength:0];
}

- (void)enqueuePCMData:(NSData *)pcmData {
    if (pcmData == nil || [pcmData length] == 0 || audioQueue == NULL) {
        return;
    }

    [queuedAudio appendData:pcmData];

    if (!isPlaying) {
        return;
    }

    if ([queuedAudio length] >= queueBufferBytes * 2) {
        AudioQueueBufferRef buffer = NULL;
        OSStatus status = AudioQueueAllocateBuffer(audioQueue, queueBufferBytes, &buffer);
        if (status == noErr && buffer != NULL) {
            UInt32 bytesToCopy = MIN((UInt32)queueBufferBytes, (UInt32)[queuedAudio length]);
            memcpy(buffer->mAudioData, [queuedAudio bytes], bytesToCopy);
            [queuedAudio replaceBytesInRange:NSMakeRange(0, bytesToCopy) withBytes:NULL length:0];
            if (bytesToCopy < queueBufferBytes) {
                memset(((unsigned char *)buffer->mAudioData) + bytesToCopy, 0, queueBufferBytes - bytesToCopy);
            }
            buffer->mAudioDataByteSize = queueBufferBytes;
            status = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, NULL);
            if (status != noErr) {
                AudioQueueFreeBuffer(audioQueue, buffer);
            }
        }
    }
}

- (BOOL)isPlaying {
    return isPlaying;
}

@end
