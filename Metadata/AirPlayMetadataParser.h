#import <Foundation/Foundation.h>

#ifndef NSINTEGER_DEFINED
typedef long NSInteger;
#define NSINTEGER_DEFINED 1
#endif

#ifndef NSUINTEGER_DEFINED
typedef unsigned long NSUInteger;
#define NSUINTEGER_DEFINED 1
#endif

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
