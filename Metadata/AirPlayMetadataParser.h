#import <Foundation/Foundation.h>

@interface AirPlayMetadataParser : NSObject {
    NSMutableDictionary *lastMetadata;
}

- (id)init;
- (NSDictionary *)lastMetadata;
- (BOOL)validatePacketAgainstSenderModel:(NSData *)packetData;
- (NSDictionary *)parsePlistData:(NSData *)data;
- (NSString *)extractStringValue:(NSString *)key fromDictionary:(NSDictionary *)dictionary;
- (NSData *)extractArtworkData:(NSDictionary *)dictionary;

@end
