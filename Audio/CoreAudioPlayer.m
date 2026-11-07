#import "CoreAudioPlayer.h"
#import <math.h>

static OSStatus AUOutputCallback(void *inRefCon,
                                AudioUnitRenderActionFlags *ioActionFlags,
                                const AudioTimeStamp *inTimeStamp,
                                UInt32 inBusNumber,
                                UInt32 inNumberFrames,
                                AudioBufferList *ioData) {
    (void)ioActionFlags;
    (void)inTimeStamp;
    (void)inBusNumber;
    CoreAudioPlayer *player = (CoreAudioPlayer *)inRefCon;
    if (player == nil) {
        return noErr;
    }
    return [player renderAudioToBufferList:ioData frames:inNumberFrames];
}

@implementation CoreAudioPlayer

- (OSStatus)renderAudioToBufferList:(AudioBufferList *)bufferList frames:(UInt32)frameCount {
    if (bufferList == NULL) {
        return noErr;
    }

    @synchronized(self) {
        UInt32 bytesRequested = frameCount * streamFormat.mBytesPerFrame;
        UInt32 bytesAvailable = (UInt32)[queuedAudio length];
        UInt32 bytesToCopy = isPlaying ? MIN(bytesRequested, bytesAvailable) : 0;
        const void *queuedBytes = [queuedAudio bytes];
        const unsigned char *sourceBytes = (const unsigned char *)queuedBytes;
        BOOL bigEndian = (streamFormat.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
        UInt32 i;

        for (i = 0; i < bufferList->mNumberBuffers; i++) {
            AudioBuffer *buffer = &bufferList->mBuffers[i];
            UInt32 copyLength = (i == 0) ? bytesToCopy : 0;
            if (buffer->mData != NULL) {
                if (copyLength > 0) {
                    if (volume >= 0.99999f || streamFormat.mBitsPerChannel != 16) {
                        memcpy(buffer->mData, queuedBytes, copyLength);
                    } else {
                        unsigned char *destinationBytes = (unsigned char *)buffer->mData;
                        UInt32 sampleOffset;
                        for (sampleOffset = 0; sampleOffset + 1 < copyLength; sampleOffset += 2) {
                            UInt16 encoded = bigEndian ?
                                (UInt16)(((UInt16)sourceBytes[sampleOffset] << 8) | sourceBytes[sampleOffset + 1]) :
                                (UInt16)(((UInt16)sourceBytes[sampleOffset + 1] << 8) | sourceBytes[sampleOffset]);
                            SInt32 sample = (encoded & 0x8000) != 0 ? (SInt32)encoded - 65536 : (SInt32)encoded;
                            SInt32 scaledSample = (SInt32)((float)sample * volume);
                            UInt16 scaledEncoded = (UInt16)(SInt16)scaledSample;
                            if (bigEndian) {
                                destinationBytes[sampleOffset] = (unsigned char)(scaledEncoded >> 8);
                                destinationBytes[sampleOffset + 1] = (unsigned char)scaledEncoded;
                            } else {
                                destinationBytes[sampleOffset] = (unsigned char)scaledEncoded;
                                destinationBytes[sampleOffset + 1] = (unsigned char)(scaledEncoded >> 8);
                            }
                        }
                    }
                }
                if (copyLength < bytesRequested) {
                    memset((unsigned char *)buffer->mData + copyLength, 0,
                           bytesRequested - copyLength);
                }
            }
            buffer->mDataByteSize = bytesRequested;
        }

        if (bytesToCopy > 0) {
            [queuedAudio replaceBytesInRange:NSMakeRange(0, bytesToCopy)
                                   withBytes:NULL
                                      length:0];
        }
    }
    return noErr;
}

- (id)initWithAudioFormat:(AudioStreamBasicDescription *)format {
    self = [super init];
    if (self != nil) {
        if (format == NULL) {
            [self release];
            return nil;
        }
        streamFormat = *format;
        outputUnit = NULL;
        isPlaying = NO;
        volume = 1.0f;
        queuedAudio = [[NSMutableData alloc] init];

        ComponentDescription description;
        memset(&description, 0, sizeof(description));
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_DefaultOutput;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;

        Component component = FindNextComponent(NULL, &description);
        ComponentInstance componentInstance = NULL;
        OSStatus status = component == NULL ? -1 : OpenAComponent(component, &componentInstance);
        if (status == noErr && componentInstance != NULL) {
            outputUnit = (AudioUnit)componentInstance;

            AURenderCallbackStruct callback;
            callback.inputProc = AUOutputCallback;
            callback.inputProcRefCon = self;

            status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, 0, &streamFormat,
                                          sizeof(streamFormat));
            if (status == noErr) {
                status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
                                              kAudioUnitScope_Input, 0, &callback,
                                              sizeof(callback));
            }
            if (status == noErr) {
                status = AudioUnitInitialize(outputUnit);
            }
        }

        if (status != noErr || outputUnit == NULL) {
            NSLog(@"CoreAudio: failed to initialize output unit (%d)", (int)status);
            if (outputUnit != NULL) {
                CloseComponent((ComponentInstance)outputUnit);
                outputUnit = NULL;
            }
        }
    }
    return self;
}

- (void)dealloc {
    if (outputUnit != NULL) {
        if (isPlaying) {
            AudioOutputUnitStop(outputUnit);
        }
        AudioUnitUninitialize(outputUnit);
        CloseComponent((ComponentInstance)outputUnit);
        outputUnit = NULL;
    }
    [queuedAudio release];
    [super dealloc];
}

- (void)start {
    if (outputUnit == NULL) {
        return;
    }

    @synchronized(self) {
        if (isPlaying) {
            return;
        }
    }

    OSStatus status = AudioOutputUnitStart(outputUnit);
    if (status == noErr) {
        @synchronized(self) {
            isPlaying = YES;
        }
    } else {
        NSLog(@"CoreAudio: failed to start output unit (%d)", (int)status);
    }
}

- (void)stop {
    if (outputUnit == NULL) {
        return;
    }

    AudioOutputUnitStop(outputUnit);
    @synchronized(self) {
        isPlaying = NO;
        [queuedAudio setLength:0];
    }
}

- (void)setVolume:(float)newVolume {
    if (newVolume < 0.0f) {
        newVolume = 0.0f;
    } else if (newVolume > 1.0f) {
        newVolume = 1.0f;
    }

    @synchronized(self) {
        volume = newVolume;
    }
}

- (void)enqueuePCMData:(NSData *)pcmData {
    if (pcmData == nil || [pcmData length] == 0 || outputUnit == NULL) {
        return;
    }

    @synchronized(self) {
        [queuedAudio appendData:pcmData];
    }
}

- (BOOL)isPlaying {
    return isPlaying;
}

@end
