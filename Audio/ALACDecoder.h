#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@interface ALACDecoder : NSObject {
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    AudioConverterRef converter;
    NSMutableData *decodeBuffer;
    NSMutableData *pendingFrameData;
    NSDictionary *lastFrameInfo;
    BOOL hasConverter;
}

- (id)init;
- (id)initWithInputFormat:(AudioStreamBasicDescription)format;
- (NSDictionary *)parseFrameHeader:(NSData *)frameData;
- (BOOL)validatePacketAgainstSenderModel:(NSData *)packetData;
- (NSData *)decodePacket:(NSData *)packetData;
- (void)reset;

@end
