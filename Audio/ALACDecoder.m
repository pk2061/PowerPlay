#import <Foundation/Foundation.h>
#import "ALACDecoder.h"

typedef struct {
    NSData *packetData;
    UInt32 channels;
    BOOL suppliedPacket;
} PowerPlayALACInput;

static OSStatus PowerPlayALACInputProc(AudioConverterRef converter,
                                       UInt32 *packetCount,
                                       AudioBufferList *inputData,
                                       AudioStreamPacketDescription **packetDescriptions,
                                       void *userData) {
    (void)converter;
    PowerPlayALACInput *input = (PowerPlayALACInput *)userData;
    if (input == NULL || packetCount == NULL || inputData == NULL ||
        input->suppliedPacket || input->packetData == nil || *packetCount == 0) {
        if (packetCount != NULL) {
            *packetCount = 0;
        }
        return noErr;
    }

    unsigned long packetLength = [input->packetData length];
    if (packetLength == 0 || packetLength > UINT32_MAX) {
        *packetCount = 0;
        return paramErr;
    }

    inputData->mNumberBuffers = 1;
    inputData->mBuffers[0].mNumberChannels = input->channels;
    inputData->mBuffers[0].mDataByteSize = (UInt32)packetLength;
    inputData->mBuffers[0].mData = (void *)[input->packetData bytes];
    if (packetDescriptions != NULL && *packetDescriptions != NULL) {
        (*packetDescriptions)[0].mStartOffset = 0;
        (*packetDescriptions)[0].mVariableFramesInPacket = 0;
        (*packetDescriptions)[0].mDataByteSize = (UInt32)packetLength;
    }

    *packetCount = 1;
    input->suppliedPacket = YES;
    return noErr;
}

static void PowerPlayWriteBigEndian16(unsigned char *bytes, UInt16 value) {
    bytes[0] = (unsigned char)(value >> 8);
    bytes[1] = (unsigned char)value;
}

static void PowerPlayWriteBigEndian32(unsigned char *bytes, UInt32 value) {
    bytes[0] = (unsigned char)(value >> 24);
    bytes[1] = (unsigned char)(value >> 16);
    bytes[2] = (unsigned char)(value >> 8);
    bytes[3] = (unsigned char)value;
}

@implementation ALACDecoder

- (id)init {
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = 44100.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = 16;
    fmt.mChannelsPerFrame = 2;
    fmt.mBytesPerPacket = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 4;
    fmt.mReserved = 0;
    return [self initWithInputFormat:fmt];
}

- (id)initWithInputFormat:(AudioStreamBasicDescription)format {
    self = [super init];
    if (self != nil) {
        inputFormat = format;
        outputFormat = format;
        pendingFrameData = [[NSMutableData alloc] init];
        lastFrameInfo = nil;
        converter = NULL;
        hasConverter = NO;
        loggedDecodeFailure = NO;
    }
    return self;
}

- (BOOL)configureWithSDP:(NSString *)sdp {
    if (sdp == nil || [sdp length] == 0) {
        return NO;
    }

    int values[11];
    BOOL foundFormat = NO;
    NSArray *lines = [sdp componentsSeparatedByString:@"\n"];
    unsigned long lineIndex;
    for (lineIndex = 0; lineIndex < [lines count]; lineIndex++) {
        NSString *line = [[lines objectAtIndex:lineIndex]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![line hasPrefix:@"a=fmtp:"]) {
            continue;
        }

        NSScanner *scanner = [NSScanner scannerWithString:line];
        NSString *prefix = nil;
        if (![scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&prefix]) {
            continue;
        }
        unsigned long valueIndex;
        for (valueIndex = 0; valueIndex < 11; valueIndex++) {
            if (![scanner scanInt:&values[valueIndex]]) {
                break;
            }
        }
        if (valueIndex == 11) {
            foundFormat = YES;
            break;
        }
    }

    if (!foundFormat || values[0] <= 0 || values[0] > 65535 ||
        values[2] <= 0 || values[2] > 32 || values[6] <= 0 || values[6] > 8 ||
        values[10] <= 0 || values[10] > 192000) {
        NSLog(@"ALAC: ANNOUNCE fmtp parameters are missing or invalid");
        return NO;
    }

    unsigned char cookieBytes[24];
    PowerPlayWriteBigEndian32(cookieBytes, (UInt32)values[0]);
    cookieBytes[4] = (unsigned char)values[1];
    cookieBytes[5] = (unsigned char)values[2];
    cookieBytes[6] = (unsigned char)values[3];
    cookieBytes[7] = (unsigned char)values[4];
    cookieBytes[8] = (unsigned char)values[5];
    cookieBytes[9] = (unsigned char)values[6];
    PowerPlayWriteBigEndian16(cookieBytes + 10, (UInt16)values[7]);
    PowerPlayWriteBigEndian32(cookieBytes + 12, (UInt32)values[8]);
    PowerPlayWriteBigEndian32(cookieBytes + 16, (UInt32)values[9]);
    PowerPlayWriteBigEndian32(cookieBytes + 20, (UInt32)values[10]);
    NSData *magicCookie = [NSData dataWithBytes:cookieBytes length:sizeof(cookieBytes)];

    AudioStreamBasicDescription alacFormat;
    memset(&alacFormat, 0, sizeof(alacFormat));
    alacFormat.mSampleRate = (Float64)values[10];
    alacFormat.mFormatID = 'alac';
    alacFormat.mChannelsPerFrame = (UInt32)values[6];
    alacFormat.mFramesPerPacket = (UInt32)values[0];

    outputFormat.mSampleRate = alacFormat.mSampleRate;
    outputFormat.mFormatID = kAudioFormatLinearPCM;
    outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    outputFormat.mBitsPerChannel = 16;
    outputFormat.mChannelsPerFrame = alacFormat.mChannelsPerFrame;
    outputFormat.mBytesPerPacket = outputFormat.mChannelsPerFrame * 2;
    outputFormat.mFramesPerPacket = 1;
    outputFormat.mBytesPerFrame = outputFormat.mChannelsPerFrame * 2;
    outputFormat.mReserved = 0;

    if (converter != NULL) {
        AudioConverterDispose(converter);
        converter = NULL;
    }
    hasConverter = NO;
    OSStatus status = AudioConverterNew(&alacFormat, &outputFormat, &converter);
    if (status != noErr || converter == NULL) {
        converter = NULL;
        NSLog(@"ALAC: AudioConverterNew failed for Apple Lossless (%d)", (int)status);
        return NO;
    }

    status = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                       (UInt32)[magicCookie length], [magicCookie bytes]);
    if (status != noErr) {
        NSLog(@"ALAC: could not set Apple Lossless magic cookie (%d)", (int)status);
        AudioConverterDispose(converter);
        converter = NULL;
        return NO;
    }

    inputFormat = alacFormat;
    hasConverter = YES;
    loggedDecodeFailure = NO;
    [self reset];
    return YES;
}

- (void)dealloc {
    if (converter != NULL) {
        AudioConverterDispose(converter);
        converter = NULL;
    }
    [pendingFrameData release];
    [lastFrameInfo release];
    [super dealloc];
}

- (void)reset {
    [pendingFrameData setLength:0];
    [lastFrameInfo release];
    lastFrameInfo = nil;
    loggedDecodeFailure = NO;
    if (converter != NULL) {
        AudioConverterReset(converter);
    }
}

- (BOOL)validatePacketAgainstSenderModel:(NSData *)packetData {
    if (packetData == nil || [packetData length] < 8) {
        return NO;
    }

    const unsigned char *bytes = [packetData bytes];
    unsigned long totalLength = [packetData length];
    if (totalLength < 8) {
        return NO;
    }

    unsigned long frameLength = ((unsigned long)bytes[0] << 24) |
                                ((unsigned long)bytes[1] << 16) |
                                ((unsigned long)bytes[2] << 8) |
                                (unsigned long)bytes[3];
    if (frameLength == 0 || frameLength + 4 != totalLength) {
        return NO;
    }

    unsigned long descriptor = ((unsigned long)bytes[4] << 8) | (unsigned long)bytes[5];
    unsigned long channels = 2;
    if (descriptor != 0) {
        channels = (descriptor & 0x0F) + 1;
    }
    if (channels == 0 || channels > 8) {
        return NO;
    }

    unsigned long sampleCount = ((unsigned long)bytes[6] << 8) | (unsigned long)bytes[7];
    if (sampleCount == 0) {
        sampleCount = frameLength / (2 * channels);
    }
    if (sampleCount == 0 || sampleCount * 2 * channels > frameLength) {
        return NO;
    }

    return YES;
}

- (NSDictionary *)parseFrameHeader:(NSData *)frameData {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (frameData == nil || [frameData length] == 0) {
        return info;
    }

    const unsigned char *bytes = [frameData bytes];
    unsigned long totalLength = [frameData length];
    unsigned long headerLength = 0;
    unsigned long frameLength = totalLength;
    unsigned long descriptor = 0;
    unsigned long sampleCountHint = 0;

    if (totalLength >= 4) {
        headerLength = 4;
        frameLength = ((unsigned long)bytes[0] << 24) |
                      ((unsigned long)bytes[1] << 16) |
                      ((unsigned long)bytes[2] << 8) |
                      (unsigned long)bytes[3];
        if (frameLength == 0 || frameLength + headerLength > totalLength) {
            frameLength = totalLength - headerLength;
            if (frameLength == 0) {
                frameLength = totalLength;
            }
        }
    }

    if (totalLength >= 8) {
        descriptor = ((unsigned long)bytes[4] << 8) | (unsigned long)bytes[5];
        sampleCountHint = ((unsigned long)bytes[6] << 8) | (unsigned long)bytes[7];
    }

    unsigned long framePayloadLength = (totalLength > headerLength) ? (totalLength - headerLength) : 0;
    unsigned long channels = 2;
    unsigned long bitsPerSample = 16;
    unsigned long samplesPerFrame = 512;

    if (descriptor != 0) {
        channels = (descriptor & 0x0F) + 1;
        if (channels == 0 || channels > 8) {
            channels = 2;
        }
    }

    if (sampleCountHint > 0) {
        samplesPerFrame = sampleCountHint;
    } else if (framePayloadLength > 0) {
        samplesPerFrame = framePayloadLength / (2 * channels);
    }

    if (samplesPerFrame == 0) {
        samplesPerFrame = 512;
    }

    if (frameLength > 0 && frameLength < headerLength) {
        frameLength = totalLength;
    }

    [info setObject:[NSNumber numberWithUnsignedLong:headerLength] forKey:@"headerLength"];
    [info setObject:[NSNumber numberWithUnsignedLong:frameLength] forKey:@"frameLength"];
    [info setObject:[NSNumber numberWithUnsignedLong:framePayloadLength] forKey:@"payloadLength"];
    [info setObject:[NSNumber numberWithUnsignedLong:channels] forKey:@"channels"];
    [info setObject:[NSNumber numberWithUnsignedLong:bitsPerSample] forKey:@"bitsPerSample"];
    [info setObject:[NSNumber numberWithUnsignedLong:samplesPerFrame] forKey:@"samplesPerFrame"];

    [lastFrameInfo release];
    lastFrameInfo = [info copy];
    return info;
}

- (NSData *)reassembleALACFrame:(NSData *)packetData {
    if (packetData == nil || [packetData length] == 0) {
        return nil;
    }

    if (![self validatePacketAgainstSenderModel:packetData]) {
        return nil;
    }

    if (pendingFrameData == nil) {
        pendingFrameData = [[NSMutableData alloc] init];
    }

    [pendingFrameData appendData:packetData];
    const unsigned char *bytes = [pendingFrameData bytes];
    unsigned long frameLength = ((unsigned long)bytes[0] << 24) |
                                ((unsigned long)bytes[1] << 16) |
                                ((unsigned long)bytes[2] << 8) |
                                (unsigned long)bytes[3];
    unsigned long totalLength = [pendingFrameData length];
    unsigned long expectedLength = 4 + frameLength;

    if (frameLength == 0 || expectedLength != totalLength) {
        [pendingFrameData setLength:0];
        return nil;
    }

    NSData *completeFrame = [NSData dataWithBytes:[pendingFrameData bytes] length:expectedLength];
    [pendingFrameData setLength:0];
    return completeFrame;
}

- (NSData *)decodePacket:(NSData *)packetData {
    if (packetData == nil || [packetData length] == 0 || !hasConverter || converter == NULL) {
        return nil;
    }

    UInt32 framesPerPacket = inputFormat.mFramesPerPacket;
    UInt32 outputCapacity = framesPerPacket * outputFormat.mBytesPerFrame;
    NSMutableData *pcmData = [NSMutableData dataWithLength:outputCapacity];
    if (pcmData == nil) {
        return nil;
    }

    PowerPlayALACInput input;
    input.packetData = packetData;
    input.channels = inputFormat.mChannelsPerFrame;
    input.suppliedPacket = NO;

    AudioBufferList output;
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = outputFormat.mChannelsPerFrame;
    output.mBuffers[0].mDataByteSize = outputCapacity;
    output.mBuffers[0].mData = [pcmData mutableBytes];
    UInt32 outputPacketCount = framesPerPacket;
    OSStatus status = AudioConverterFillComplexBuffer(converter, PowerPlayALACInputProc,
                                                       &input, &outputPacketCount,
                                                       &output, NULL);
    if (status != noErr || output.mBuffers[0].mDataByteSize == 0) {
        if (!loggedDecodeFailure) {
            NSLog(@"ALAC: AudioConverterFillComplexBuffer failed (%d), output packets=%u",
                  (int)status, outputPacketCount);
            loggedDecodeFailure = YES;
        }
        return nil;
    }

    [pcmData setLength:output.mBuffers[0].mDataByteSize];
    return pcmData;
}

@end
