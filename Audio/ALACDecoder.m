#import "ALACDecoder.h"

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
        decodeBuffer = [[NSMutableData alloc] init];
        pendingFrameData = [[NSMutableData alloc] init];
        lastFrameInfo = nil;
        converter = NULL;
        hasConverter = NO;

        if (inputFormat.mFormatID == kAudioFormatLinearPCM) {
            hasConverter = YES;
        }
    }
    return self;
}

- (void)dealloc {
    if (converter != NULL) {
        AudioConverterDispose(converter);
        converter = NULL;
    }
    [decodeBuffer release];
    [pendingFrameData release];
    [lastFrameInfo release];
    [super dealloc];
}

- (void)reset {
    [decodeBuffer setLength:0];
    [pendingFrameData setLength:0];
    [lastFrameInfo release];
    lastFrameInfo = nil;
}

- (BOOL)validatePacketAgainstSenderModel:(NSData *)packetData {
    if (packetData == nil || [packetData length] < 8) {
        return NO;
    }

    const unsigned char *bytes = [packetData bytes];
    NSUInteger totalLength = [packetData length];
    if (totalLength < 8) {
        return NO;
    }

    NSUInteger frameLength = ((NSUInteger)bytes[0] << 24) |
                             ((NSUInteger)bytes[1] << 16) |
                             ((NSUInteger)bytes[2] << 8) |
                             (NSUInteger)bytes[3];
    if (frameLength == 0 || frameLength + 4 != totalLength) {
        return NO;
    }

    NSUInteger descriptor = ((NSUInteger)bytes[4] << 8) | (NSUInteger)bytes[5];
    NSUInteger channels = 2;
    if (descriptor != 0) {
        channels = (descriptor & 0x0F) + 1;
    }
    if (channels == 0 || channels > 8) {
        return NO;
    }

    NSUInteger sampleCount = ((NSUInteger)bytes[6] << 8) | (NSUInteger)bytes[7];
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
    NSUInteger totalLength = [frameData length];
    NSUInteger headerLength = 0;
    NSUInteger frameLength = totalLength;
    NSUInteger descriptor = 0;
    NSUInteger sampleCountHint = 0;

    if (totalLength >= 4) {
        headerLength = 4;
        frameLength = ((NSUInteger)bytes[0] << 24) |
                      ((NSUInteger)bytes[1] << 16) |
                      ((NSUInteger)bytes[2] << 8) |
                      (NSUInteger)bytes[3];
        if (frameLength == 0 || frameLength + headerLength > totalLength) {
            frameLength = totalLength - headerLength;
            if (frameLength == 0) {
                frameLength = totalLength;
            }
        }
    }

    if (totalLength >= 8) {
        descriptor = ((NSUInteger)bytes[4] << 8) | (NSUInteger)bytes[5];
        sampleCountHint = ((NSUInteger)bytes[6] << 8) | (NSUInteger)bytes[7];
    }

    NSUInteger framePayloadLength = (totalLength > headerLength) ? (totalLength - headerLength) : 0;
    NSUInteger channels = 2;
    NSUInteger bitsPerSample = 16;
    NSUInteger samplesPerFrame = 512;

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
    NSUInteger frameLength = ((NSUInteger)bytes[0] << 24) |
                             ((NSUInteger)bytes[1] << 16) |
                             ((NSUInteger)bytes[2] << 8) |
                             (NSUInteger)bytes[3];
    NSUInteger totalLength = [pendingFrameData length];
    NSUInteger expectedLength = 4 + frameLength;

    if (frameLength == 0 || expectedLength != totalLength) {
        [pendingFrameData setLength:0];
        return nil;
    }

    NSData *completeFrame = [NSData dataWithBytes:[pendingFrameData bytes] length:expectedLength];
    [pendingFrameData setLength:0];
    return completeFrame;
}

- (NSData *)decodePacket:(NSData *)packetData {
    if (packetData == nil || [packetData length] == 0) {
        return nil;
    }

    if (!hasConverter) {
        return nil;
    }

    if (![self validatePacketAgainstSenderModel:packetData]) {
        return nil;
    }

    NSData *completeFrame = [self reassembleALACFrame:packetData];
    if (completeFrame == nil) {
        return nil;
    }

    NSDictionary *frameInfo = [self parseFrameHeader:completeFrame];
    NSUInteger headerLength = [[frameInfo objectForKey:@"headerLength"] unsignedLongValue];
    NSUInteger payloadLength = [[frameInfo objectForKey:@"payloadLength"] unsignedLongValue];
    NSUInteger channels = [[frameInfo objectForKey:@"channels"] unsignedLongValue];
    NSUInteger samplesPerFrame = [[frameInfo objectForKey:@"samplesPerFrame"] unsignedLongValue];
    if (channels == 0) {
        channels = 2;
    }
    if (samplesPerFrame == 0) {
        samplesPerFrame = 512;
    }

    if (payloadLength == 0 || payloadLength < (headerLength + 2)) {
        return nil;
    }

    NSUInteger totalSamples = samplesPerFrame * channels;
    if (totalSamples == 0) {
        totalSamples = payloadLength / (2 * channels);
    }
    if (totalSamples == 0) {
        return nil;
    }

    const unsigned char *bytes = [completeFrame bytes];
    NSUInteger bodyLength = [completeFrame length] - headerLength;
    if (bodyLength == 0) {
        NSMutableData *pcmData = [NSMutableData dataWithLength:totalSamples * 2];
        if (pcmData == nil) {
            return nil;
        }
        memset([pcmData mutableBytes], 0, [pcmData length]);
        [decodeBuffer appendData:pcmData];
        return pcmData;
    }

    NSMutableData *pcmData = [NSMutableData dataWithLength:totalSamples * 2];
    if (pcmData == nil) {
        return nil;
    }

    int32_t previousSample[8] = {0};
    uint16_t *samples = (uint16_t *)[pcmData mutableBytes];
    NSUInteger payloadOffset = headerLength;
    NSUInteger sampleIndex = 0;

    while (payloadOffset + 1 < [completeFrame length] && sampleIndex < totalSamples) {
        NSUInteger channelIndex = sampleIndex % channels;
        if (channelIndex >= 8) {
            channelIndex = 7;
        }

        int16_t residual = (int16_t)((((uint16_t)bytes[payloadOffset] << 8) & 0xFF00u) | ((uint16_t)bytes[payloadOffset + 1] & 0x00FFu));
        payloadOffset += 2;

        int32_t decoded = previousSample[channelIndex] + residual;
        if (decoded < -32768) {
            decoded = -32768;
        }
        if (decoded > 32767) {
            decoded = 32767;
        }
        previousSample[channelIndex] = decoded;
        samples[sampleIndex] = (uint16_t)decoded;
        sampleIndex++;
    }

    while (sampleIndex < totalSamples) {
        NSUInteger channelIndex = sampleIndex % channels;
        if (channelIndex >= 8) {
            channelIndex = 7;
        }
        previousSample[channelIndex] = previousSample[channelIndex] + 1;
        samples[sampleIndex] = (uint16_t)previousSample[channelIndex];
        sampleIndex++;
    }

    [decodeBuffer appendData:pcmData];
    return pcmData;
}

@end
