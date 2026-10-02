#import "CoreAudioPlayer.h"

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

    UInt32 bytesRequested = frameCount * streamFormat.mBytesPerFrame;
    UInt32 bytesAvailable = (UInt32)[queuedAudio length];
    UInt32 bytesToCopy = isPlaying ? MIN(bytesRequested, bytesAvailable) : 0;
    const void *queuedBytes = [queuedAudio bytes];

    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        AudioBuffer *buffer = &bufferList->mBuffers[i];
        UInt32 copyLength = (i == 0) ? bytesToCopy : 0;
        if (buffer->mData != NULL) {
            if (copyLength > 0) {
                memcpy(buffer->mData, queuedBytes, copyLength);
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
    return noErr;
}

- (id)initWithFormat:(AudioStreamBasicDescription)format {
    self = [super init];
    if (self != nil) {
        streamFormat = format;
        outputUnit = NULL;
        isPlaying = NO;
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

    if (!isPlaying) {
        OSStatus status = AudioOutputUnitStart(outputUnit);
        if (status == noErr) {
            isPlaying = YES;
        } else {
            NSLog(@"CoreAudio: failed to start output unit (%d)", (int)status);
        }
    }
}

- (void)stop {
    if (outputUnit == NULL) {
        return;
    }

    AudioOutputUnitStop(outputUnit);
    isPlaying = NO;
    [queuedAudio setLength:0];
}

- (void)enqueuePCMData:(NSData *)pcmData {
    if (pcmData == nil || [pcmData length] == 0 || outputUnit == NULL) {
        return;
    }

    [queuedAudio appendData:pcmData];
}

- (BOOL)isPlaying {
    return isPlaying;
}

@end
