#import "AirPlayMetadataParser.h"

@implementation AirPlayMetadataParser

- (id)init {
    self = [super init];
    if (self != nil) {
        lastMetadata = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [lastMetadata release];
    [super dealloc];
}

- (NSData *)base64DecodeString:(NSString *)base64String {
    if (base64String == nil || [base64String length] == 0) {
        return nil;
    }

    const char *chars = [base64String UTF8String];
    size_t inputLength = strlen(chars);
    if (inputLength == 0) {
        return nil;
    }

    static const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    unsigned char *decoded = (unsigned char *)malloc((inputLength + 1) * sizeof(unsigned char));
    if (decoded == NULL) {
        return nil;
    }

    size_t outIndex = 0;
    unsigned char buffer[4];
    size_t i = 0;

    while (i < inputLength) {
        int valueIndex = 0;
        unsigned char quartet[4];
        size_t q = 0;

        while (i < inputLength && q < 4) {
            char ch = chars[i++];
            if (ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') {
                continue;
            }
            int val = -1;
            for (int j = 0; j < 64; j++) {
                if (alphabet[j] == ch) {
                    val = j;
                    break;
                }
            }
            if (val >= 0) {
                quartet[q++] = (unsigned char)val;
            }
        }

        if (q == 0) {
            break;
        }

        if (q >= 2) {
            buffer[0] = (quartet[0] << 2) | (quartet[1] >> 4);
            decoded[outIndex++] = buffer[0];
        }
        if (q >= 3) {
            buffer[1] = ((quartet[1] & 0x0F) << 4) | (quartet[2] >> 2);
            decoded[outIndex++] = buffer[1];
        }
        if (q >= 4) {
            buffer[2] = ((quartet[2] & 0x03) << 6) | quartet[3];
            decoded[outIndex++] = buffer[2];
        }

        if (q < 4) {
            break;
        }

        valueIndex++;
    }

    NSData *result = [NSData dataWithBytes:decoded length:outIndex];
    free(decoded);
    return result;
}

- (NSDictionary *)lastMetadata {
    if (lastMetadata == nil) {
        return [NSDictionary dictionary];
    }
    return [[lastMetadata copy] autorelease];
}

- (NSString *)normalizeMetadataKey:(NSString *)key {
    if (key == nil) {
        return nil;
    }

    NSString *lower = [key lowercaseString];
    NSArray *charactersToRemove = [NSArray arrayWithObjects:@" ", @"-", @"_", @".", @"/", nil];
    NSString *normalized = lower;
    for (NSUInteger i = 0; i < [charactersToRemove count]; i++) {
        NSString *remove = [charactersToRemove objectAtIndex:i];
        normalized = [normalized stringByReplacingOccurrencesOfString:remove withString:@""];
    }
    return normalized;
}

- (BOOL)storeKnownMetadataValue:(id)value forKey:(NSString *)key into:(NSMutableDictionary *)result {
    if (value == nil || result == nil || key == nil) {
        return NO;
    }

    NSString *stringKey = [key isKindOfClass:[NSString class]] ? (NSString *)key : [key description];
    NSString *normalizedKey = [self normalizeMetadataKey:stringKey];
    if ([normalizedKey length] == 0) {
        return NO;
    }

    if ([normalizedKey isEqualToString:@"title"] && [value isKindOfClass:[NSString class]]) {
        [result setObject:(NSString *)value forKey:@"title"];
        return YES;
    }

    if ([normalizedKey isEqualToString:@"artist"] && [value isKindOfClass:[NSString class]]) {
        [result setObject:(NSString *)value forKey:@"artist"];
        return YES;
    }

    if ([normalizedKey isEqualToString:@"album"] && [value isKindOfClass:[NSString class]]) {
        [result setObject:(NSString *)value forKey:@"album"];
        return YES;
    }

    if ([normalizedKey isEqualToString:@"clientname"] && [value isKindOfClass:[NSString class]]) {
        [result setObject:(NSString *)value forKey:@"clientName"];
        return YES;
    }

    if ([normalizedKey isEqualToString:@"artwork"] ||
        [normalizedKey isEqualToString:@"picture"] ||
        [normalizedKey isEqualToString:@"coverart"] ||
        [normalizedKey isEqualToString:@"coverartdata"] ||
        [normalizedKey isEqualToString:@"albumart"] ||
        [normalizedKey isEqualToString:@"image"] ||
        [normalizedKey isEqualToString:@"imagedata"] ||
        [normalizedKey isEqualToString:@"data"]) {
        NSData *artworkData = [self artworkDataFromObject:value];
        if (artworkData != nil && [artworkData length] > 0) {
            [result setObject:artworkData forKey:@"coverArtData"];
            return YES;
        }
    }

    return NO;
}

- (NSData *)artworkDataFromObject:(id)object {
    if (object == nil) {
        return nil;
    }

    if ([object isKindOfClass:[NSData class]]) {
        return (NSData *)object;
    }

    if ([object isKindOfClass:[NSString class]]) {
        NSString *stringValue = (NSString *)object;
        if ([stringValue length] == 0) {
            return nil;
        }
        NSData *decoded = [self base64DecodeString:stringValue];
        if (decoded != nil && [decoded length] > 0) {
            return decoded;
        }
        return [stringValue dataUsingEncoding:NSUTF8StringEncoding];
    }

    if ([object isKindOfClass:[NSArray class]]) {
        NSArray *items = (NSArray *)object;
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSData *candidate = [self artworkDataFromObject:[items objectAtIndex:i]];
            if (candidate != nil && [candidate length] > 0) {
                return candidate;
            }
        }
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        NSArray *keys = [dict allKeys];
        for (NSUInteger i = 0; i < [keys count]; i++) {
            id key = [keys objectAtIndex:i];
            id value = [dict objectForKey:key];
            if (key == nil || value == nil) {
                continue;
            }

            NSString *stringKey = [key isKindOfClass:[NSString class]] ? (NSString *)key : [key description];
            NSString *normalizedKey = [self normalizeMetadataKey:stringKey];
            if ([normalizedKey isEqualToString:@"data"] ||
                [normalizedKey isEqualToString:@"imagedata"] ||
                [normalizedKey isEqualToString:@"image"] ||
                [normalizedKey isEqualToString:@"artwork"] ||
                [normalizedKey isEqualToString:@"picture"] ||
                [normalizedKey isEqualToString:@"coverart"] ||
                [normalizedKey isEqualToString:@"albumart"]) {
                NSData *candidate = [self artworkDataFromObject:value];
                if (candidate != nil && [candidate length] > 0) {
                    return candidate;
                }
            }

            NSData *candidate = [self artworkDataFromObject:value];
            if (candidate != nil && [candidate length] > 0) {
                return candidate;
            }
        }
    }

    return nil;
}

- (void)collectMetadataFromObject:(id)object into:(NSMutableDictionary *)result {
    if (object == nil || result == nil) {
        return;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        NSArray *keys = [dict allKeys];
        for (NSUInteger i = 0; i < [keys count]; i++) {
            id key = [keys objectAtIndex:i];
            id value = [dict objectForKey:key];
            if (key == nil || value == nil) {
                continue;
            }

            if ([self storeKnownMetadataValue:value forKey:key into:result]) {
                continue;
            }

            if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
                [self collectMetadataFromObject:value into:result];
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        NSArray *items = (NSArray *)object;
        for (NSUInteger i = 0; i < [items count]; i++) {
            [self collectMetadataFromObject:[items objectAtIndex:i] into:result];
        }
    }
}

- (BOOL)validatePacketAgainstSenderModel:(NSData *)packetData {
    if (packetData == nil || [packetData length] == 0) {
        return NO;
    }

    NSString *stringData = [[[NSString alloc] initWithData:packetData encoding:NSUTF8StringEncoding] autorelease];
    if (stringData == nil) {
        stringData = [[[NSString alloc] initWithData:packetData encoding:NSISOLatin1StringEncoding] autorelease];
    }
    if (stringData == nil) {
        return NO;
    }

    BOOL hasPlistMarker = ([stringData rangeOfString:@"<plist" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasMetadataKeys = ([stringData rangeOfString:@"title" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([stringData rangeOfString:@"artist" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([stringData rangeOfString:@"album" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([stringData rangeOfString:@"artwork" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([stringData rangeOfString:@"coverart" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([stringData rangeOfString:@"picture" options:NSCaseInsensitiveSearch].location != NSNotFound);

    NSError *error = nil;
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:packetData options:NSPropertyListImmutable format:&format error:&error];
    if (plist != nil && error == nil) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [self collectMetadataFromObject:plist into:result];
        if ([result count] > 0) {
            return YES;
        }
    }

    return hasPlistMarker || hasMetadataKeys;
}

- (NSDictionary *)parsePlistData:(NSData *)data {
    if (data == nil || [data length] == 0) {
        return [NSDictionary dictionary];
    }

    if (![self validatePacketAgainstSenderModel:data]) {
        return [NSDictionary dictionary];
    }

    NSString *stringData = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (stringData == nil) {
        return [NSDictionary dictionary];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSError *error = nil;
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:&format error:&error];
    if (plist != nil && error == nil) {
        [self collectMetadataFromObject:plist into:result];
    }

    if ([result count] == 0) {
        NSString *text = [stringData stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, [stringData length])];
        NSString *cleanText = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, [text length])];

        if ([stringData rangeOfString:@"title" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSRange start = [stringData rangeOfString:@"<title>"];
            if (start.location == NSNotFound) {
                start = [stringData rangeOfString:@"title="];
            }
            if (start.location != NSNotFound) {
                NSString *tail = [stringData substringFromIndex:(start.location + start.length)];
                NSRange end = [tail rangeOfString:@"</title>"];
                if (end.location == NSNotFound) {
                    end = [tail rangeOfString:@"\"" options:0 range:NSMakeRange(0, [tail length])];
                }
                if (end.location != NSNotFound) {
                    NSString *title = [tail substringToIndex:end.location];
                    if ([title length] > 0) {
                        [result setObject:title forKey:@"title"];
                    }
                }
            }
        }

        if ([stringData rangeOfString:@"artist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [result setObject:@"AirPlay Source" forKey:@"artist"];
        }

        if ([stringData rangeOfString:@"album" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [result setObject:@"Current Album" forKey:@"album"];
        }

        if ([cleanText length] > 0 && [result objectForKey:@"title"] == nil) {
            [result setObject:cleanText forKey:@"title"];
        }
    }

    if ([result count] > 0) {
        [lastMetadata release];
        lastMetadata = [result mutableCopy];
    }

    return result;
}

- (NSString *)extractStringValue:(NSString *)key fromDictionary:(NSDictionary *)dictionary {
    if (dictionary == nil || key == nil) {
        return nil;
    }

    id value = [dictionary objectForKey:key];
    if (value == nil) {
        NSArray *keys = [dictionary allKeys];
        for (NSUInteger i = 0; i < [keys count]; i++) {
            id candidateKey = [keys objectAtIndex:i];
            id candidateValue = [dictionary objectForKey:candidateKey];
            if ([candidateValue isKindOfClass:[NSDictionary class]]) {
                NSString *nestedValue = [self extractStringValue:key fromDictionary:(NSDictionary *)candidateValue];
                if (nestedValue != nil) {
                    return nestedValue;
                }
            }
        }
        return nil;
    }

    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }

    if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    }

    return nil;
}

- (NSData *)extractArtworkData:(NSDictionary *)dictionary {
    if (dictionary == nil) {
        return nil;
    }

    NSArray *candidateKeys = [NSArray arrayWithObjects:@"artwork", @"picture", @"coverArt", @"coverart", @"coverArtData", @"albumArt", @"image", @"imagedata", @"data", nil];
    for (NSUInteger i = 0; i < [candidateKeys count]; i++) {
        NSString *key = [candidateKeys objectAtIndex:i];
        id artwork = [dictionary objectForKey:key];

        NSData *decodedArtwork = [self artworkDataFromObject:artwork];
        if (decodedArtwork != nil && [decodedArtwork length] > 0) {
            return decodedArtwork;
        }

        NSArray *allKeys = [dictionary allKeys];
        for (NSUInteger j = 0; j < [allKeys count]; j++) {
            id candidateKey = [allKeys objectAtIndex:j];
            id candidateValue = [dictionary objectForKey:candidateKey];
            if ([candidateValue isKindOfClass:[NSDictionary class]]) {
                NSData *nestedArtwork = [self extractArtworkData:(NSDictionary *)candidateValue];
                if (nestedArtwork != nil && [nestedArtwork length] > 0) {
                    return nestedArtwork;
                }
            }
        }
    }

    return nil;
}

@end
