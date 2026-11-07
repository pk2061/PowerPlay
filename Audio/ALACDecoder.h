#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@interface ALACDecoder : NSObject {
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    AudioConverterRef converter;
    NSMutableData *pendingFrameData;
    NSDictionary *lastFrameInfo;
    BOOL hasConverter;
    BOOL loggedDecodeFailure;
}

- (id)init;
- (id)initWithInputFormat:(AudioStreamBasicDescription)format;
- (BOOL)configureWithSDP:(NSString *)sdp;
- (NSDictionary *)parseFrameHeader:(NSData *)frameData;
- (BOOL)validatePacketAgainstSenderModel:(NSData *)packetData;
- (NSData *)decodePacket:(NSData *)packetData;
- (void)reset;

@end
