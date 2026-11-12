#import "RAOPReceiver.h"

#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <stdio.h>
#import <math.h>
#import <stdlib.h>

NSString * const PowerPlayMetadataDidChangeNotification = @"PowerPlayMetadataDidChangeNotification";
NSString * const PowerPlayVolumeDidChangeNotification = @"PowerPlayVolumeDidChangeNotification";
NSString * const PowerPlayPlaybackProgressDidChangeNotification = @"PowerPlayPlaybackProgressDidChangeNotification";

typedef struct bio_st PowerPlayBIO;
typedef struct rsa_st PowerPlayRSA;
typedef struct {
    unsigned int roundKeys[60];
    int rounds;
} PowerPlayAESKey;

enum {
    PowerPlayRSAPKCS1Padding = 1,
    PowerPlayRSAOAEPPadding = 4,
    PowerPlayAESDecrypt = 0
};

static float PowerPlayLinearGainFromDecibels(float decibels) {
    if (decibels <= -144.0f) {
        return 0.0f;
    }
    if (decibels >= 0.0f) {
        return 1.0f;
    }
    return powf(10.0f, decibels / 20.0f);
}

static float PowerPlayDecibelsFromLinearGain(float gain) {
    if (gain <= 0.0f) {
        return -144.0f;
    }
    if (gain >= 1.0f) {
        return 0.0f;
    }
    return 20.0f * log10f(gain);
}

static BOOL PowerPlayParseUInt32(NSString *string, uint32_t *value) {
    if (string == nil || value == NULL) {
        return NO;
    }

    const char *start = [string UTF8String];
    if (start == NULL || *start == '\0') {
        return NO;
    }
    errno = 0;
    char *end = NULL;
    unsigned long parsedValue = strtoul(start, &end, 10);
    if (end == start || *end != '\0' || errno == ERANGE || parsedValue > 0xFFFFFFFFUL) {
        return NO;
    }
    *value = (uint32_t)parsedValue;
    return YES;
}

static double PowerPlayCurrentTime(void) {
    struct timeval now;
    if (gettimeofday(&now, NULL) != 0) {
        return 0.0;
    }
    return (double)now.tv_sec + ((double)now.tv_usec / 1000000.0);
}

static void PowerPlayWriteNTPTime(unsigned char *bytes) {
    struct timeval now;
    gettimeofday(&now, NULL);
    uint64_t seconds = (uint64_t)now.tv_sec + 2208988800ULL;
    uint64_t fraction = ((uint64_t)now.tv_usec << 32) / 1000000ULL;
    bytes[0] = (unsigned char)(seconds >> 24);
    bytes[1] = (unsigned char)(seconds >> 16);
    bytes[2] = (unsigned char)(seconds >> 8);
    bytes[3] = (unsigned char)seconds;
    bytes[4] = (unsigned char)(fraction >> 24);
    bytes[5] = (unsigned char)(fraction >> 16);
    bytes[6] = (unsigned char)(fraction >> 8);
    bytes[7] = (unsigned char)fraction;
}

extern PowerPlayBIO *BIO_new_file(const char *filename, const char *mode);
extern PowerPlayRSA *PEM_read_bio_RSAPrivateKey(PowerPlayBIO *bio, PowerPlayRSA **rsa, void *callback, void *userData);
extern int BIO_free(PowerPlayBIO *bio);
extern int RSA_size(const PowerPlayRSA *rsa);
extern int RSA_private_encrypt(int inputLength, const unsigned char *input, unsigned char *output, PowerPlayRSA *rsa, int padding);
extern int RSA_private_decrypt(int inputLength, const unsigned char *input, unsigned char *output, PowerPlayRSA *rsa, int padding);
extern void RSA_free(PowerPlayRSA *rsa);
extern int AES_set_decrypt_key(const unsigned char *userKey, int bits, PowerPlayAESKey *key);
extern void AES_cbc_encrypt(const unsigned char *input, unsigned char *output, size_t length,
                            const PowerPlayAESKey *key, unsigned char *ivec, int enc);

static NSString *PowerPlayDeviceIdentifier(void) {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *interface = NULL;
    char deviceID[13] = "000000000001";
    char fallbackID[13] = "";

    if (getifaddrs(&interfaces) == 0) {
        for (interface = interfaces; interface != NULL; interface = interface->ifa_next) {
            if (interface->ifa_addr == NULL || interface->ifa_addr->sa_family != AF_LINK ||
                (interface->ifa_flags & IFF_LOOPBACK) != 0) {
                continue;
            }

            struct sockaddr_dl *linkAddress = (struct sockaddr_dl *)interface->ifa_addr;
            if (linkAddress->sdl_alen != 6) {
                continue;
            }

            const unsigned char *address = (const unsigned char *)LLADDR(linkAddress);
            char candidate[13];
            snprintf(candidate, sizeof(candidate), "%02X%02X%02X%02X%02X%02X",
                     address[0], address[1], address[2], address[3], address[4], address[5]);
            if (fallbackID[0] == '\0') {
                memcpy(fallbackID, candidate, sizeof(fallbackID));
            }
            if (strcmp(interface->ifa_name, "en0") == 0) {
                memcpy(deviceID, candidate, sizeof(deviceID));
                break;
            }
        }
        freeifaddrs(interfaces);
    }

    if (strcmp(deviceID, "000000000001") == 0 && fallbackID[0] != '\0') {
        memcpy(deviceID, fallbackID, sizeof(deviceID));
    }
    return [NSString stringWithCString:deviceID encoding:NSASCIIStringEncoding];
}

static int PowerPlayBase64Value(unichar character) {
    if (character >= 'A' && character <= 'Z') return (int)(character - 'A');
    if (character >= 'a' && character <= 'z') return (int)(character - 'a') + 26;
    if (character >= '0' && character <= '9') return (int)(character - '0') + 52;
    if (character == '+') return 62;
    if (character == '/') return 63;
    return -1;
}

static NSData *PowerPlayDecodeBase64(NSString *encoded) {
    if (encoded == nil || [encoded length] == 0) {
        return nil;
    }

    NSMutableData *decoded = [NSMutableData data];
    unsigned int accumulator = 0;
    int bits = 0;
    BOOL paddingStarted = NO;
    NSUInteger i;
    for (i = 0; i < [encoded length]; i++) {
        unichar character = [encoded characterAtIndex:i];
        if (character == '=') {
            paddingStarted = YES;
            continue;
        }
        if (paddingStarted) {
            return nil;
        }

        int value = PowerPlayBase64Value(character);
        if (value < 0) {
            return nil;
        }
        accumulator = (accumulator << 6) | (unsigned int)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            unsigned char byte = (unsigned char)((accumulator >> bits) & 0xFF);
            [decoded appendBytes:&byte length:1];
        }
    }

    if (bits >= 6 || (bits > 0 && (accumulator & ((1U << bits) - 1U)) != 0)) {
        return nil;
    }
    return decoded;
}

static NSString *PowerPlayEncodeBase64WithoutPadding(const unsigned char *bytes, NSUInteger length) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    NSMutableString *encoded = [NSMutableString string];
    NSUInteger i;
    for (i = 0; i < length; i += 3) {
        NSUInteger remaining = length - i;
        unsigned int triple = (unsigned int)bytes[i] << 16;
        if (remaining > 1) triple |= (unsigned int)bytes[i + 1] << 8;
        if (remaining > 2) triple |= (unsigned int)bytes[i + 2];

        [encoded appendFormat:@"%c%c", alphabet[(triple >> 18) & 0x3F], alphabet[(triple >> 12) & 0x3F]];
        if (remaining > 1) [encoded appendFormat:@"%c", alphabet[(triple >> 6) & 0x3F]];
        if (remaining > 2) [encoded appendFormat:@"%c", alphabet[triple & 0x3F]];
    }
    return encoded;
}

static int PowerPlayHexValue(unichar character) {
    if (character >= '0' && character <= '9') return (int)(character - '0');
    if (character >= 'A' && character <= 'F') return (int)(character - 'A') + 10;
    if (character >= 'a' && character <= 'f') return (int)(character - 'a') + 10;
    return -1;
}

static BOOL PowerPlayDecodeDeviceIdentifier(NSString *identifier, unsigned char bytes[6]) {
    if (identifier == nil || [identifier length] != 12) {
        return NO;
    }

    NSUInteger i;
    for (i = 0; i < 6; i++) {
        int high = PowerPlayHexValue([identifier characterAtIndex:i * 2]);
        int low = PowerPlayHexValue([identifier characterAtIndex:i * 2 + 1]);
        if (high < 0 || high > 15 || low < 0 || low > 15) {
            return NO;
        }
        bytes[i] = (unsigned char)((high << 4) | low);
    }
    return YES;
}

static PowerPlayRSA *PowerPlayLoadPrivateKey(void) {
    NSString *keyPath = [[NSBundle mainBundle] pathForResource:@"RAOPPrivateKey" ofType:@"pem"];
    PowerPlayBIO *keyFile = keyPath == nil ? NULL : BIO_new_file([keyPath fileSystemRepresentation], "r");
    PowerPlayRSA *privateKey = keyFile == NULL ? NULL : PEM_read_bio_RSAPrivateKey(keyFile, NULL, NULL, NULL);
    if (keyFile != NULL) {
        BIO_free(keyFile);
    }
    return privateKey;
}

static NSString *PowerPlayAppleResponse(NSString *challenge, int socketHandle, NSString *identifier) {
    NSData *challengeData = PowerPlayDecodeBase64(challenge);
    if (challengeData == nil || [challengeData length] > 16) {
        return nil;
    }

    struct sockaddr_in localAddress;
    socklen_t localLength = sizeof(localAddress);
    memset(&localAddress, 0, sizeof(localAddress));
    if (getsockname(socketHandle, (struct sockaddr *)&localAddress, &localLength) != 0 ||
        localAddress.sin_family != AF_INET) {
        return nil;
    }

    unsigned char identifierBytes[6];
    if (!PowerPlayDecodeDeviceIdentifier(identifier, identifierBytes)) {
        return nil;
    }

    unsigned char signedData[48];
    memset(signedData, 0, sizeof(signedData));
    NSUInteger signedLength = [challengeData length];
    memcpy(signedData, [challengeData bytes], signedLength);
    memcpy(signedData + signedLength, &localAddress.sin_addr.s_addr, sizeof(localAddress.sin_addr.s_addr));
    signedLength += sizeof(localAddress.sin_addr.s_addr);
    memcpy(signedData + signedLength, identifierBytes, sizeof(identifierBytes));
    signedLength += sizeof(identifierBytes);
    if (signedLength < 32) {
        signedLength = 32;
    }

    PowerPlayRSA *privateKey = PowerPlayLoadPrivateKey();
    if (privateKey == NULL) {
        return nil;
    }

    int signatureCapacity = RSA_size(privateKey);
    unsigned char *signature = (unsigned char *)malloc((size_t)signatureCapacity);
    int signatureLength = signature == NULL ? -1 : RSA_private_encrypt(
        (int)signedLength, signedData, signature, privateKey, PowerPlayRSAPKCS1Padding);
    RSA_free(privateKey);
    if (signatureLength <= 0) {
        free(signature);
        return nil;
    }

    NSString *response = PowerPlayEncodeBase64WithoutPadding(signature, (NSUInteger)signatureLength);
    free(signature);
    return response;
}

static NSData *PowerPlayDecryptAudioKey(NSData *encryptedKey) {
    if (encryptedKey == nil || [encryptedKey length] == 0) {
        NSLog(@"RAOP: ANNOUNCE rsaaeskey Base64 decoding failed");
        return nil;
    }

    PowerPlayRSA *privateKey = PowerPlayLoadPrivateKey();
    if (privateKey == NULL) {
        NSLog(@"RAOP: could not load private key for audio-key decryption");
        return nil;
    }

    int decryptedCapacity = RSA_size(privateKey);
    unsigned char *decryptedKey = decryptedCapacity > 0 ? (unsigned char *)malloc((size_t)decryptedCapacity) : NULL;
    int decryptedLength = decryptedKey == NULL ? -1 : RSA_private_decrypt(
        (int)[encryptedKey length], [encryptedKey bytes], decryptedKey, privateKey, PowerPlayRSAOAEPPadding);
    RSA_free(privateKey);

    if (decryptedLength != 16) {
        NSLog(@"RAOP: RSA audio-key decryption returned %d bytes (ciphertext=%lu, RSA size=%d)",
              decryptedLength, (unsigned long)[encryptedKey length], decryptedCapacity);
    }
    NSData *audioKey = decryptedLength == 16 ?
        [NSData dataWithBytes:decryptedKey length:(NSUInteger)decryptedLength] : nil;
    free(decryptedKey);
    return audioKey;
}

static NSDictionary *PowerPlayAudioEncryptionFromSDP(NSString *sdp) {
    if (sdp == nil || [sdp length] == 0) {
        return nil;
    }

    NSString *encryptedKeyText = nil;
    NSString *ivText = nil;
    NSArray *lines = [sdp componentsSeparatedByString:@"\n"];
    NSUInteger i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [[lines objectAtIndex:i]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line hasPrefix:@"a=rsaaeskey:"]) {
            encryptedKeyText = [line substringFromIndex:[@"a=rsaaeskey:" length]];
        } else if ([line hasPrefix:@"a=aesiv:"]) {
            ivText = [line substringFromIndex:[@"a=aesiv:" length]];
        }
    }

    NSData *encryptedKey = PowerPlayDecodeBase64(encryptedKeyText);
    NSData *audioIV = PowerPlayDecodeBase64(ivText);
    if (encryptedKey == nil || audioIV == nil) {
        NSLog(@"RAOP: ANNOUNCE Base64 fields invalid (key=%@, IV=%@)",
              encryptedKey == nil ? @"invalid" : @"decoded",
              audioIV == nil ? @"invalid" : @"decoded");
    } else if ([audioIV length] != 16) {
        NSLog(@"RAOP: ANNOUNCE AES IV decoded to %lu bytes (expected 16)",
              (unsigned long)[audioIV length]);
    }
    NSData *audioKey = PowerPlayDecryptAudioKey(encryptedKey);
    if (audioKey == nil || [audioIV length] != 16) {
        return nil;
    }

    return [NSDictionary dictionaryWithObjectsAndKeys:
        audioKey, @"key",
        audioIV, @"iv",
        nil];
}

static BOOL PowerPlayRTPPayloadRange(NSData *packet, NSRange *payloadRange) {
    if (packet == nil || payloadRange == NULL || [packet length] < 12) {
        return NO;
    }

    const unsigned char *bytes = [packet bytes];
    if (((bytes[0] >> 6) & 0x03) != 2) {
        return NO;
    }

    NSUInteger packetLength = [packet length];
    NSUInteger headerLength = 12 + (NSUInteger)(bytes[0] & 0x0F) * 4;
    if (headerLength > packetLength) {
        return NO;
    }

    if ((bytes[0] & 0x10) != 0) {
        if (packetLength - headerLength < 4) {
            return NO;
        }
        NSUInteger extensionWords = ((NSUInteger)bytes[headerLength + 2] << 8) |
                                   (NSUInteger)bytes[headerLength + 3];
        NSUInteger extensionLength = 4 + extensionWords * 4;
        if (extensionLength > packetLength - headerLength) {
            return NO;
        }
        headerLength += extensionLength;
    }

    NSUInteger paddingLength = 0;
    if ((bytes[0] & 0x20) != 0) {
        paddingLength = bytes[packetLength - 1];
        if (paddingLength == 0 || paddingLength > packetLength - headerLength) {
            return NO;
        }
    }

    NSUInteger payloadLength = packetLength - headerLength - paddingLength;
    if (payloadLength == 0) {
        return NO;
    }

    *payloadRange = NSMakeRange(headerLength, payloadLength);
    return YES;
}

static NSData *PowerPlayDecryptRTPPayload(NSData *packet, NSRange payloadRange, NSData *key, NSData *iv) {
    if (packet == nil || key == nil || [key length] != 16 || iv == nil || [iv length] != 16 ||
        NSMaxRange(payloadRange) > [packet length]) {
        return nil;
    }

    NSUInteger encryptedLength = payloadRange.length & ~(NSUInteger)0x0F;
    if (encryptedLength == 0) {
        return nil;
    }

    NSMutableData *decrypted = [NSMutableData dataWithLength:payloadRange.length];
    const unsigned char *input = (const unsigned char *)[packet bytes] + payloadRange.location;
    unsigned char *output = [decrypted mutableBytes];
    PowerPlayAESKey keySchedule;
    unsigned char ivCopy[16];
    memset(&keySchedule, 0, sizeof(keySchedule));
    memcpy(ivCopy, [iv bytes], sizeof(ivCopy));
    if (AES_set_decrypt_key([key bytes], 128, &keySchedule) != 0) {
        memset(&keySchedule, 0, sizeof(keySchedule));
        return nil;
    }
    AES_cbc_encrypt(input, output, encryptedLength, &keySchedule, ivCopy, PowerPlayAESDecrypt);
    memset(&keySchedule, 0, sizeof(keySchedule));

    if (encryptedLength < payloadRange.length) {
        memcpy(output + encryptedLength, input + encryptedLength, payloadRange.length - encryptedLength);
    }
    return decrypted;
}

static NSUInteger PowerPlayRTSPHeaderEnd(const unsigned char *bytes, NSUInteger length) {
    NSUInteger i;
    for (i = 0; i + 3 < length; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n' &&
            bytes[i + 2] == '\r' && bytes[i + 3] == '\n') {
            return i;
        }
    }
    return NSNotFound;
}

static const NSUInteger PowerPlayMaximumRTSPHeaderBytes = 65536;
static const NSUInteger PowerPlayMaximumRTSPBodyBytes = 8 * 1024 * 1024;

static NSDictionary *PowerPlayReadRTSPRequest(int socketHandle) {
    NSMutableData *buffer = [NSMutableData data];
    unsigned char chunk[4096];
    NSUInteger headerEnd = NSNotFound;
    NSUInteger contentLength = 0;
    BOOL haveContentLength = NO;
    NSString *headerText = nil;
    NSArray *headerLines = nil;

    for (;;) {
        const unsigned char *bytes = [buffer bytes];
        if (headerEnd == NSNotFound) {
            headerEnd = PowerPlayRTSPHeaderEnd(bytes, [buffer length]);
            if (headerEnd != NSNotFound) {
                headerText = [[[NSString alloc] initWithBytes:bytes
                                                       length:headerEnd
                                                     encoding:NSASCIIStringEncoding] autorelease];
                if (headerText == nil) {
                    NSLog(@"RAOP: rejected RTSP headers that are not valid ASCII");
                    return nil;
                }
                headerLines = [headerText componentsSeparatedByString:@"\r\n"];
                NSUInteger lineIndex;
                for (lineIndex = 1; lineIndex < [headerLines count]; lineIndex++) {
                    NSString *line = [headerLines objectAtIndex:lineIndex];
                    NSRange colon = [line rangeOfString:@":"];
                    if (colon.location == NSNotFound) {
                        continue;
                    }
                    NSString *key = [[line substringToIndex:colon.location] lowercaseString];
                    if ([key isEqualToString:@"content-length"]) {
                        NSString *value = [[line substringFromIndex:colon.location + 1]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        int lengthValue = [value intValue];
                        if (lengthValue < 0 || (NSUInteger)lengthValue > PowerPlayMaximumRTSPBodyBytes) {
                            NSLog(@"RAOP: rejected RTSP Content-Length value: %@", value);
                            return nil;
                        }
                        contentLength = (NSUInteger)lengthValue;
                        haveContentLength = YES;
                        break;
                    }
                }
                if (!haveContentLength) {
                    contentLength = 0;
                }
            } else if ([buffer length] > PowerPlayMaximumRTSPHeaderBytes) {
                NSLog(@"RAOP: rejected RTSP header larger than %lu bytes",
                      (unsigned long)PowerPlayMaximumRTSPHeaderBytes);
                return nil;
            }
        }

        if (headerEnd != NSNotFound &&
            [buffer length] >= headerEnd + 4 + contentLength) {
            NSMutableDictionary *headers = [NSMutableDictionary dictionary];
            NSUInteger lineIndex;
            for (lineIndex = 1; lineIndex < [headerLines count]; lineIndex++) {
                NSString *line = [headerLines objectAtIndex:lineIndex];
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location == NSNotFound) {
                    continue;
                }
                NSString *key = [[line substringToIndex:colon.location] lowercaseString];
                NSString *value = [[line substringFromIndex:colon.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                [headers setObject:value forKey:key];
            }

            NSString *requestLine = [headerLines count] > 0 ? [headerLines objectAtIndex:0] : @"";
            NSData *body = [NSData dataWithBytes:(bytes + headerEnd + 4) length:contentLength];
            return [NSDictionary dictionaryWithObjectsAndKeys:
                requestLine, @"requestLine",
                headers, @"headers",
                body, @"body", nil];
        }

        ssize_t received = recv(socketHandle, chunk, sizeof(chunk), 0);
        if (received <= 0) {
            if (received == 0) {
                NSLog(@"RAOP: RTSP peer closed the connection");
            } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT) {
                NSLog(@"RAOP: RTSP request read timed out (%d)", errno);
            } else {
                NSLog(@"RAOP: RTSP request read failed (%d)", errno);
            }
            return nil;
        }
        [buffer appendBytes:chunk length:(NSUInteger)received];
        NSUInteger maximumRequestBytes = PowerPlayMaximumRTSPHeaderBytes + 4 + PowerPlayMaximumRTSPBodyBytes;
        if ([buffer length] > maximumRequestBytes) {
            NSLog(@"RAOP: rejected RTSP request larger than %lu bytes",
                  (unsigned long)maximumRequestBytes);
            return nil;
        }
    }
}

static void PowerPlaySendRTSPResponse(int socketHandle, NSString *response) {
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = [responseData bytes];
    NSUInteger remaining = [responseData length];
    while (remaining > 0) {
        ssize_t sent = send(socketHandle, bytes, remaining, 0);
        if (sent <= 0) {
            return;
        }
        bytes += sent;
        remaining -= (NSUInteger)sent;
    }
}

static NSString *PowerPlayRTSPHeaderValue(NSString *response, NSString *headerName) {
    if (response == nil || headerName == nil || [headerName length] == 0) {
        return nil;
    }

    NSArray *lines = [response componentsSeparatedByString:@"\r\n"];
    NSUInteger i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        if ([line length] == 0) {
            continue;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([[key lowercaseString] isEqualToString:[headerName lowercaseString]]) {
            return value;
        }
    }
    return nil;
}

static void PowerPlayLogAndSendRTSPResponse(int socketHandle, NSString *response) {
    if (response == nil || [response length] == 0) {
        NSLog(@"RAOP: sending empty RTSP response");
        return;
    }

    NSArray *responseLines = [response componentsSeparatedByString:@"\r\n"];
    NSString *statusLine = [responseLines count] > 0 ? [responseLines objectAtIndex:0] : @"";
    NSString *cseq = PowerPlayRTSPHeaderValue(response, @"CSeq");
    NSString *session = PowerPlayRTSPHeaderValue(response, @"Session");
    NSString *transport = PowerPlayRTSPHeaderValue(response, @"Transport");
    NSString *contentType = PowerPlayRTSPHeaderValue(response, @"Content-Type");
    NSString *contentLength = PowerPlayRTSPHeaderValue(response, @"Content-Length");

    NSString *body = nil;
    NSRange split = [response rangeOfString:@"\r\n\r\n"];
    if (split.location != NSNotFound && split.location + split.length < [response length]) {
        body = [response substringFromIndex:(split.location + split.length)];
    }

    NSUInteger bodyLength = body == nil ? 0 : [body lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    NSLog(@"RAOP: raw RTSP response:\n%@", response);
    NSLog(@"RAOP: RTSP response summary: status=%@ cseq=%@ session=%@ transport=%@ content-type=%@ content-length=%@ body-bytes=%lu",
          statusLine,
          cseq == nil ? @"<none>" : cseq,
          session == nil ? @"<none>" : session,
          transport == nil ? @"<none>" : transport,
          contentType == nil ? @"<none>" : contentType,
          contentLength == nil ? @"<none>" : contentLength,
          (unsigned long)bodyLength);

    PowerPlaySendRTSPResponse(socketHandle, response);
}

static NSInteger PowerPlayTransportPort(NSString *transport, NSString *portName) {
    if (transport == nil || portName == nil) {
        return 0;
    }
    NSArray *parts = [transport componentsSeparatedByString:@";"];
    NSUInteger i;
    for (i = 0; i < [parts count]; i++) {
        NSString *part = [[parts objectAtIndex:i]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange equals = [part rangeOfString:@"="];
        if (equals.location == NSNotFound) {
            continue;
        }
        NSString *key = [[part substringToIndex:equals.location] lowercaseString];
        if ([key isEqualToString:[portName lowercaseString]]) {
            return [[part substringFromIndex:equals.location + 1] intValue];
        }
    }
    return 0;
}

@implementation RAOPReceiver

- (void)updateDACPIdentityFromHeaders:(NSDictionary *)headers {
    NSString *newIdentifier = [headers objectForKey:@"dacp-id"];
    NSString *newActiveRemote = [headers objectForKey:@"active-remote"];
    BOOL shouldSearch = NO;

    @synchronized(self) {
        if ([newIdentifier isKindOfClass:[NSString class]] && [newIdentifier length] > 0 &&
            ![newIdentifier isEqualToString:dacpIdentifier]) {
            [dacpIdentifier release];
            dacpIdentifier = [newIdentifier copy];
            shouldSearch = YES;
        }
        if ([newActiveRemote isKindOfClass:[NSString class]] && [newActiveRemote length] > 0 &&
            ![newActiveRemote isEqualToString:dacpActiveRemote]) {
            [dacpActiveRemote release];
            dacpActiveRemote = [newActiveRemote copy];
            shouldSearch = YES;
        }
    }

    if (shouldSearch) {
        NSLog(@"RAOP: received sender DACP identity (DACP-ID present=%d, Active-Remote present=%d)",
              [newIdentifier length] > 0, [newActiveRemote length] > 0);
        [self performSelectorOnMainThread:@selector(startDACPServiceDiscovery)
                               withObject:nil waitUntilDone:NO];
    }
}

- (void)startDACPServiceDiscovery {
    NSString *identifier;
    @synchronized(self) {
        identifier = [dacpIdentifier copy];
    }
    if ([identifier length] == 0) {
        [identifier release];
        return;
    }

    NSString *normalizedIdentifier = [identifier uppercaseString];
    if ([normalizedIdentifier length] < 16) {
        NSString *padding = [@"0000000000000000" substringToIndex:
            16 - [normalizedIdentifier length]];
        normalizedIdentifier = [NSString stringWithFormat:@"%@%@", padding, normalizedIdentifier];
    }
    NSString *serviceName = [NSString stringWithFormat:@"iTunes_Ctrl_%@", normalizedIdentifier];
    [identifier release];

    if ([serviceName isEqualToString:dacpSearchName] && dacpServiceBrowser != nil) {
        return;
    }
    [self stopDACPServiceDiscovery];
    [dacpSearchName release];
    dacpSearchName = [serviceName copy];
    dacpServiceBrowser = [[NSNetServiceBrowser alloc] init];
    [dacpServiceBrowser setDelegate:self];
    [dacpServiceBrowser searchForServicesOfType:@"_dacp._tcp." inDomain:@"local."];
    NSLog(@"RAOP: searching for DACP Bonjour service %@", dacpSearchName);
}

- (void)stopDACPServiceDiscovery {
    [dacpServiceBrowser stop];
    [dacpServiceBrowser setDelegate:nil];
    [dacpServiceBrowser release];
    dacpServiceBrowser = nil;
    [dacpService stop];
    [dacpService setDelegate:nil];
    [dacpService release];
    dacpService = nil;
    @synchronized(self) {
        [dacpAddress release];
        dacpAddress = nil;
        dacpPort = 0;
    }
    [self notifyMetadataDidChange];
}

- (void)sendDACPCommand:(NSString *)command {
    NSString *address;
    NSString *activeRemote;
    NSInteger port;
    @synchronized(self) {
        address = [dacpAddress retain];
        activeRemote = [dacpActiveRemote retain];
        port = dacpPort;
    }
    NSCharacterSet *lineBreaks = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    if ([address length] == 0 || [activeRemote length] == 0 ||
        [activeRemote length] > 128 ||
        [activeRemote rangeOfCharacterFromSet:lineBreaks].location != NSNotFound || port <= 0) {
        NSLog(@"RAOP: cannot send DACP command %@; sender remote service is not ready", command);
        [address release];
        [activeRemote release];
        return;
    }

    NSDictionary *request = [NSDictionary dictionaryWithObjectsAndKeys:
        command, @"command", address, @"address", activeRemote, @"activeRemote",
        [NSNumber numberWithInteger:port], @"port", nil];
    [NSThread detachNewThreadSelector:@selector(sendDACPCommandOnThread:)
                             toTarget:self withObject:request];
    [address release];
    [activeRemote release];
}

- (void)sendDACPCommandOnThread:(NSDictionary *)request {
    NSAutoreleasePool *threadPool = [[NSAutoreleasePool alloc] init];
    NSString *command = [request objectForKey:@"command"];
    NSString *host = [request objectForKey:@"address"];
    NSString *activeRemote = [request objectForKey:@"activeRemote"];
    NSInteger port = [[request objectForKey:@"port"] integerValue];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portString[16];
    snprintf(portString, sizeof(portString), "%ld", (long)port);

    struct addrinfo *addresses = NULL;
    int lookupResult = getaddrinfo([host UTF8String], portString, &hints, &addresses);
    if (lookupResult != 0) {
        NSLog(@"RAOP: DACP %@ address lookup failed (%d)", command, lookupResult);
        [threadPool drain];
        return;
    }

    int socketHandle = -1;
    struct addrinfo *address;
    for (address = addresses; address != NULL; address = address->ai_next) {
        socketHandle = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketHandle < 0) {
            continue;
        }
        int noSignal = 1;
        setsockopt(socketHandle, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        struct timeval timeout;
        timeout.tv_sec = 2;
        timeout.tv_usec = 0;
        setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socketHandle, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        if (connect(socketHandle, address->ai_addr, address->ai_addrlen) == 0) {
            break;
        }
        close(socketHandle);
        socketHandle = -1;
    }
    freeaddrinfo(addresses);
    if (socketHandle < 0) {
        NSLog(@"RAOP: DACP %@ connection failed", command);
        [threadPool drain];
        return;
    }

    NSString *httpRequest = [NSString stringWithFormat:
        @"GET /ctrl-int/1/%@ HTTP/1.1\r\nHost: %@:%ld\r\nActive-Remote: %@\r\nConnection: close\r\nUser-Agent: PowerPlay/1.0\r\n\r\n",
        command, host, (long)port, activeRemote];
    NSData *requestData = [httpRequest dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = [requestData bytes];
    NSUInteger remaining = [requestData length];
    while (remaining > 0) {
        ssize_t sent = send(socketHandle, bytes, remaining, 0);
        if (sent < 0 && errno == EINTR) {
            continue;
        }
        if (sent <= 0) {
            break;
        }
        bytes += sent;
        remaining -= (NSUInteger)sent;
    }

    if (remaining == 0) {
        char response[1024];
        ssize_t received = recv(socketHandle, response, sizeof(response) - 1, 0);
        if (received > 0) {
            response[received] = '\0';
            char *lineEnd = strstr(response, "\r\n");
            if (lineEnd != NULL) {
                *lineEnd = '\0';
            }
            NSLog(@"RAOP: DACP %@ response: %s", command, response);
        } else {
            NSLog(@"RAOP: DACP %@ sent; no response received (%d)", command, errno);
        }
    } else {
        NSLog(@"RAOP: DACP %@ request send failed (%d)", command, errno);
    }

    close(socketHandle);
    [threadPool drain];
}

- (id)init {
    self = [super init];
    if (self != nil) {
        publishedService = nil;
        deviceIdentifier = nil;
        dacpServiceBrowser = nil;
        dacpService = nil;
        dacpIdentifier = nil;
        dacpActiveRemote = nil;
        dacpAddress = nil;
        dacpSearchName = nil;
        dacpPort = 0;
        listenerSocket = -1;
        rtpControlSocket = -1;
        acceptingRTSP = NO;
        currentTitle = [[NSString alloc] initWithString:@"Waiting for AirPlay source..."]; 
        coverArtData = nil;
        isPlaying = NO;
        volume = 0.5f;
        elapsedPlaybackTime = 0.0;
        trackDuration = 0.0;
        progressReferenceTime = 0.0;
        lastAudioPacketTime = 0.0;
        progressResumeOffset = 0.0;
        lastProgressStartTimestamp = 0;
        lastProgressCurrentTimestamp = 0;
        hasProgressTimestamp = NO;
        resumeProgressPending = NO;
        progressIsRelative = NO;
        controlPort = 5000;
        audioPort = 6000;
        timingPort = 6002;
        rtpControlPort = 6001;
        senderTimingPort = 0;
        incomingSessionActive = NO;
        connectedDeviceName = nil;
        hasExplicitClientName = NO;
        controlSocket = -1;
        audioSocket = -1;
        timingSocket = -1;
        nextCSeq = 1;
        rtspSessionEstablished = NO;
        rtpSessionReady = NO;
        isSetupComplete = NO;
        rtspSessionId = nil;
        hostAddress = nil;
        artistName = nil;
        albumName = nil;
        trackName = nil;
        metadata = [[NSMutableDictionary alloc] init];
        audioAESKey = nil;
        audioAESIV = nil;
        alacDecoder = [[ALACDecoder alloc] init];
        metadataParser = [[AirPlayMetadataParser alloc] init];

        AudioStreamBasicDescription format;
        memset(&format, 0, sizeof(format));
        format.mSampleRate = 44100.0;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        format.mBitsPerChannel = 16;
        format.mChannelsPerFrame = 2;
        format.mBytesPerPacket = 4;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = 4;

        audioPlayer = [[CoreAudioPlayer alloc] initWithAudioFormat:&format];
        [audioPlayer setVolume:volume];
    }
    return self;
}

- (void)dealloc {
    [self stopReceiver];
    if (controlSocket >= 0) {
        close(controlSocket);
        controlSocket = -1;
    }
    if (audioSocket >= 0) {
        close(audioSocket);
        audioSocket = -1;
    }
    if (timingSocket >= 0) {
        close(timingSocket);
        timingSocket = -1;
    }
    if (rtpControlSocket >= 0) {
        close(rtpControlSocket);
        rtpControlSocket = -1;
    }
    [publishedService release];
    [deviceIdentifier release];
    [dacpIdentifier release];
    [dacpActiveRemote release];
    [dacpAddress release];
    [dacpSearchName release];
    [connectedDeviceName release];
    [currentTitle release];
    [coverArtData release];
    [resolvedService release];
    [rtspSessionId release];
    [hostAddress release];
    [artistName release];
    [albumName release];
    [trackName release];
    [metadata release];
    [audioAESKey release];
    [audioAESIV release];
    [alacDecoder release];
    [metadataParser release];
    [audioPlayer release];
    [super dealloc];
}

- (void)startReceiver {
    if (listenerSocket >= 0) {
        return;
    }

    int serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (serverSocket < 0) {
        NSLog(@"RAOP: could not create RTSP listener (%d)", errno);
        return;
    }

    int reuse = 1;
    setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in localAddress;
    memset(&localAddress, 0, sizeof(localAddress));
    localAddress.sin_family = AF_INET;
    localAddress.sin_port = 0;
    localAddress.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(serverSocket, (struct sockaddr *)&localAddress, sizeof(localAddress)) != 0 ||
        listen(serverSocket, 4) != 0) {
        NSLog(@"RAOP: could not bind RTSP listener (%d)", errno);
        close(serverSocket);
        return;
    }

    socklen_t addressLength = sizeof(localAddress);
    if (getsockname(serverSocket, (struct sockaddr *)&localAddress, &addressLength) != 0) {
        NSLog(@"RAOP: could not determine RTSP port (%d)", errno);
        close(serverSocket);
        return;
    }

    listenerSocket = serverSocket;
    acceptingRTSP = YES;
    [NSThread detachNewThreadSelector:@selector(acceptRTSPConnections)
                             toTarget:self
                           withObject:nil];
        [NSThread detachNewThreadSelector:@selector(receiveAudioPackets)
                                                         toTarget:self
                                                     withObject:nil];
        [NSThread detachNewThreadSelector:@selector(receiveControlPackets)
                                                         toTarget:self
                                                     withObject:nil];
        [NSThread detachNewThreadSelector:@selector(receiveTimingPackets)
                                                         toTarget:self
                                                     withObject:nil];

    [deviceIdentifier release];
    deviceIdentifier = [PowerPlayDeviceIdentifier() copy];
    NSString *serviceName = [NSString stringWithFormat:@"%@@PowerPlay", deviceIdentifier];
    publishedService = [[NSNetService alloc] initWithDomain:@"local."
                                                        type:@"_raop._tcp."
                                                        name:serviceName
                                                        port:ntohs(localAddress.sin_port)];
    [publishedService setDelegate:self];

    NSMutableDictionary *txtRecord = [NSMutableDictionary dictionary];
    [txtRecord setObject:[@"1" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"txtvers"];
    [txtRecord setObject:[@"2" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"ch"];
    [txtRecord setObject:[@"0,1" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"cn"];
    [txtRecord setObject:[@"0,1" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"et"];
    [txtRecord setObject:[@"0,1,2" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"md"];
    [txtRecord setObject:[@"false" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"pw"];
    [txtRecord setObject:[@"44100" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"sr"];
    [txtRecord setObject:[@"16" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"ss"];
    [txtRecord setObject:[@"false" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"sv"];
    [txtRecord setObject:[@"UDP" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"tp"];
    [txtRecord setObject:[@"3" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"vn"];
    [txtRecord setObject:[@"220.68" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"vs"];
    [publishedService setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txtRecord]];
    [publishedService publish];

    NSLog(@"RAOP: publishing %@ on TCP port %u", serviceName, (unsigned int)ntohs(localAddress.sin_port));
}

- (void)stopReceiver {
    acceptingRTSP = NO;
    if (publishedService != nil) {
        [publishedService stop];
        [publishedService setDelegate:nil];
        [publishedService release];
        publishedService = nil;
    }
    if (listenerSocket >= 0) {
        shutdown(listenerSocket, SHUT_RDWR);
        close(listenerSocket);
        listenerSocket = -1;
    }
    if ([NSThread isMainThread]) {
        [self stopDACPServiceDiscovery];
    } else {
        [self performSelectorOnMainThread:@selector(stopDACPServiceDiscovery)
                               withObject:nil waitUntilDone:YES];
    }
    [self teardownSession];
}

- (void)acceptRTSPConnections {
    NSAutoreleasePool *threadPool = [[NSAutoreleasePool alloc] init];
    while (acceptingRTSP) {
        int serverSocket = listenerSocket;
        struct sockaddr_in peerAddress;
        socklen_t peerLength = sizeof(peerAddress);
        int incomingSocket = accept(serverSocket, (struct sockaddr *)&peerAddress, &peerLength);
        if (incomingSocket < 0) {
            if (!acceptingRTSP) {
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            NSLog(@"RAOP: RTSP accept failed (%d)", errno);
            continue;
        }

        NSLog(@"RAOP: accepted RTSP connection from %s:%u",
              inet_ntoa(peerAddress.sin_addr), (unsigned int)ntohs(peerAddress.sin_port));

        struct timeval receiveTimeout;
        receiveTimeout.tv_sec = 30;
        receiveTimeout.tv_usec = 0;
        setsockopt(incomingSocket, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
        NSAutoreleasePool *connectionPool = [[NSAutoreleasePool alloc] init];
        [self handleRTSPConnection:incomingSocket];
        close(incomingSocket);
        [connectionPool drain];
    }
    [threadPool drain];
}

- (void)resetSessionAfterDisconnect {
    [audioPlayer stop];

    if (audioSocket >= 0) {
        close(audioSocket);
        audioSocket = -1;
    }
    if (timingSocket >= 0) {
        close(timingSocket);
        timingSocket = -1;
    }
    if (rtpControlSocket >= 0) {
        close(rtpControlSocket);
        rtpControlSocket = -1;
    }

    @synchronized(self) {
        incomingSessionActive = NO;
        isPlaying = NO;
        rtspSessionEstablished = NO;
        rtpSessionReady = NO;
        isSetupComplete = NO;
        elapsedPlaybackTime = 0.0;
        trackDuration = 0.0;
        progressReferenceTime = 0.0;
        lastAudioPacketTime = 0.0;
        progressResumeOffset = 0.0;
        lastProgressStartTimestamp = 0;
        lastProgressCurrentTimestamp = 0;
        hasProgressTimestamp = NO;
        resumeProgressPending = NO;
        progressIsRelative = NO;

        [currentTitle release];
        currentTitle = [[NSString alloc] initWithString:@"Waiting for AirPlay source..."];
        [trackName release];
        trackName = nil;
        [artistName release];
        artistName = nil;
        [albumName release];
        albumName = nil;
        [coverArtData release];
        coverArtData = nil;
        [audioAESKey release];
        audioAESKey = nil;
        [audioAESIV release];
        audioAESIV = nil;
        [connectedDeviceName release];
        connectedDeviceName = nil;
        hasExplicitClientName = NO;
        [dacpIdentifier release];
        dacpIdentifier = nil;
        [dacpActiveRemote release];
        dacpActiveRemote = nil;
        [hostAddress release];
        hostAddress = nil;
    }

    [self performSelectorOnMainThread:@selector(stopDACPServiceDiscovery)
                           withObject:nil waitUntilDone:NO];

    [self notifyMetadataDidChange];
}

- (void)handleRTSPConnection:(int)incomingSocket {
    struct sockaddr_in peerAddress;
    socklen_t peerLength = sizeof(peerAddress);
    memset(&peerAddress, 0, sizeof(peerAddress));
    @synchronized(self) {
        incomingSessionActive = YES;
        [connectedDeviceName release];
        connectedDeviceName = nil;
        hasExplicitClientName = NO;
    }
    if (getpeername(incomingSocket, (struct sockaddr *)&peerAddress, &peerLength) == 0) {
        NSString *peerAddressString = [NSString stringWithUTF8String:inet_ntoa(peerAddress.sin_addr)];
        char peerName[NI_MAXHOST];
        NSString *resolvedPeerName = nil;
        if (getnameinfo((struct sockaddr *)&peerAddress, peerLength,
                        peerName, sizeof(peerName), NULL, 0, NI_NAMEREQD) == 0) {
            resolvedPeerName = [NSString stringWithUTF8String:peerName];
            if ([[resolvedPeerName lowercaseString] hasSuffix:@".local"]) {
                resolvedPeerName = [resolvedPeerName substringToIndex:[resolvedPeerName length] - 6];
            }
        }
        @synchronized(self) {
            [hostAddress release];
            hostAddress = [peerAddressString copy];
            if ([resolvedPeerName length] > 0) {
                [connectedDeviceName release];
                connectedDeviceName = [resolvedPeerName copy];
            }
        }
    }
    [self notifyMetadataDidChange];

    [rtspSessionId release];
    rtspSessionId = [[NSString stringWithFormat:@"PowerPlay-%u-%u",
        (unsigned int)getpid(), (unsigned int)time(NULL)] copy];
    rtspSessionEstablished = NO;
    isSetupComplete = NO;
    rtpSessionReady = NO;
    isPlaying = NO;

    NSString *lastRTSPRequest = @"<none>";
    while (acceptingRTSP) {
        NSDictionary *request = PowerPlayReadRTSPRequest(incomingSocket);
        if (request == nil) {
            NSLog(@"RAOP: ending RTSP connection loop after %@ (setup=%d playing=%d)",
                  lastRTSPRequest, isSetupComplete, isPlaying);
            break;
        }

        NSString *requestLine = [request objectForKey:@"requestLine"];
        NSArray *requestParts = [requestLine componentsSeparatedByString:@" "];
        if ([requestParts count] < 2) {
            NSLog(@"RAOP: ending RTSP connection on malformed request line: %@", requestLine);
            break;
        }
        NSString *method = [[requestParts objectAtIndex:0] uppercaseString];
        NSDictionary *headers = [request objectForKey:@"headers"];
        [self updateDACPIdentityFromHeaders:headers];
        NSData *requestBodyData = [request objectForKey:@"body"];
        NSString *reportedClientName = [headers objectForKey:@"x-apple-client-name"];
        if (reportedClientName == nil || [reportedClientName length] == 0) {
            reportedClientName = [headers objectForKey:@"x-apple-device-name"];
        }
        reportedClientName = [reportedClientName stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([reportedClientName length] > 0) {
            BOOL clientNameChanged = NO;
            @synchronized(self) {
                clientNameChanged = ![reportedClientName isEqualToString:connectedDeviceName];
                hasExplicitClientName = YES;
                if (clientNameChanged) {
                    [connectedDeviceName release];
                    connectedDeviceName = [reportedClientName copy];
                }
            }
            if (clientNameChanged) {
                [self notifyMetadataDidChange];
            }
        }
        NSString *requestBodyText = requestBodyData == nil ? @"" : [[[NSString alloc] initWithData:requestBodyData encoding:NSUTF8StringEncoding] autorelease];
        NSString *requestParameter = requestBodyText == nil ? @"" : [requestBodyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *cseq = [headers objectForKey:@"cseq"];
        if (cseq == nil) {
            cseq = @"1";
        }
        lastRTSPRequest = [NSString stringWithFormat:@"%@ CSeq %@", method, cseq];
        NSString *sessionHeader = [headers objectForKey:@"session"];
        NSString *transport = [headers objectForKey:@"transport"];
        NSString *requestContentType = [headers objectForKey:@"content-type"];
        NSString *status = @"200 OK";
        NSString *responseHeaders = @"";
        NSString *responseBody = nil;
        NSString *contentType = nil;

        NSLog(@"RAOP: received RTSP request: %@", requestLine);
        NSLog(@"RAOP: RTSP request headers: %@", headers);
        if ([requestParameter length] > 0) {
            NSLog(@"RAOP: RTSP request parameter body: %@", requestParameter);
        }

        if ([method isEqualToString:@"OPTIONS"]) {
            responseHeaders = @"Public: OPTIONS, ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, SET_PARAMETER, GET_PARAMETER\r\n";
            NSString *challenge = [headers objectForKey:@"apple-challenge"];
            if (challenge != nil) {
                NSString *appleResponse = PowerPlayAppleResponse(challenge, incomingSocket, deviceIdentifier);
                if (appleResponse != nil) {
                    responseHeaders = [responseHeaders stringByAppendingFormat:
                        @"Apple-Response: %@\r\n", appleResponse];
                } else {
                    NSLog(@"RAOP: could not generate Apple-Response for the received challenge");
                }
            }
        } else if ([method isEqualToString:@"ANNOUNCE"]) {
            NSArray *sdpLines = [requestParameter componentsSeparatedByString:@"\n"];
            NSUInteger sdpLineIndex;
            for (sdpLineIndex = 0; sdpLineIndex < [sdpLines count]; sdpLineIndex++) {
                NSString *sdpLine = [[sdpLines objectAtIndex:sdpLineIndex]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (![sdpLine hasPrefix:@"i="]) {
                    continue;
                }

                NSString *sdpDeviceName = [[sdpLine substringFromIndex:2]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                BOOL deviceNameChanged = NO;
                @synchronized(self) {
                    if (!hasExplicitClientName && [sdpDeviceName length] > 0) {
                        deviceNameChanged = ![sdpDeviceName isEqualToString:connectedDeviceName];
                        if (deviceNameChanged) {
                            [connectedDeviceName release];
                            connectedDeviceName = [sdpDeviceName copy];
                        }
                    }
                }
                if (deviceNameChanged) {
                    NSLog(@"RAOP: using SDP session name as AirPlay device name: %@", sdpDeviceName);
                    [self notifyMetadataDidChange];
                }
                break;
            }

            NSDictionary *audioEncryption = PowerPlayAudioEncryptionFromSDP(requestParameter);
            NSData *newAudioAESKey = [audioEncryption objectForKey:@"key"];
            NSData *newAudioAESIV = [audioEncryption objectForKey:@"iv"];
            BOOL audioFormatReady = [alacDecoder configureWithSDP:requestParameter];
            @synchronized(self) {
                [audioAESKey release];
                [audioAESIV release];
                audioAESKey = [newAudioAESKey retain];
                audioAESIV = [newAudioAESIV retain];
            }
            if (newAudioAESKey != nil && newAudioAESIV != nil) {
                NSLog(@"RAOP: ANNOUNCE audio AES key decrypted and IV parsed");
            } else {
                NSLog(@"RAOP: unable to decrypt ANNOUNCE audio key or parse IV");
            }
            if (!audioFormatReady) {
                NSLog(@"RAOP: could not configure Apple Lossless decoder from ANNOUNCE fmtp");
            } else {
                NSLog(@"RAOP: Apple Lossless decoder configured from ANNOUNCE fmtp");
            }
            rtspSessionEstablished = YES;
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
        } else if ([method isEqualToString:@"SETUP"]) {
            if (!rtspSessionEstablished) {
                status = @"455 Method Not Valid in This State";
            } else if (transport == nil || [transport rangeOfString:@"RTP/AVP/UDP" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                status = @"461 Unsupported Transport";
            } else {
                NSInteger senderControlPort = PowerPlayTransportPort(transport, @"control_port");
                NSInteger remoteTimingPort = PowerPlayTransportPort(transport, @"timing_port");
                senderTimingPort = remoteTimingPort;
                if (audioSocket >= 0) {
                    close(audioSocket);
                    audioSocket = -1;
                }
                if (rtpControlSocket >= 0) {
                    close(rtpControlSocket);
                    rtpControlSocket = -1;
                }
                if (timingSocket >= 0) {
                    close(timingSocket);
                    timingSocket = -1;
                }

                BOOL audioBound = [self openUDPListenerOnPort:audioPort socket:&audioSocket];
                BOOL controlBound = audioBound && [self openUDPListenerOnPort:rtpControlPort socket:&rtpControlSocket];
                BOOL timingBound = controlBound && [self openUDPListenerOnPort:timingPort socket:&timingSocket];
                if (!timingBound) {
                    if (audioSocket >= 0) { close(audioSocket); audioSocket = -1; }
                    if (rtpControlSocket >= 0) { close(rtpControlSocket); rtpControlSocket = -1; }
                    if (timingSocket >= 0) { close(timingSocket); timingSocket = -1; }
                    status = @"500 Internal Server Error";
                } else {
                    isSetupComplete = YES;
                    rtpSessionReady = YES;
                    [metadata setObject:[NSNumber numberWithInt:(int)senderControlPort] forKey:@"sender_control_port"];
                    [metadata setObject:[NSNumber numberWithInt:(int)remoteTimingPort] forKey:@"sender_timing_port"];
                    responseHeaders = [NSString stringWithFormat:
                        @"Session: %@;timeout=60\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port=%ld;control_port=%ld;timing_port=%ld\r\n",
                        rtspSessionId, (long)audioPort, (long)rtpControlPort, (long)timingPort];
                }
            }
        } else if ([method isEqualToString:@"RECORD"]) {
            if (!isSetupComplete || (sessionHeader != nil && ![sessionHeader hasPrefix:rtspSessionId])) {
                status = @"455 Method Not Valid in This State";
            } else {
                @synchronized(self) {
                    isPlaying = YES;
                    progressReferenceTime = PowerPlayCurrentTime();
                }
                NSLog(@"RAOP: sender resumed playback");
                [audioPlayer start];
                responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            }
        } else if ([method isEqualToString:@"PAUSE"]) {
            @synchronized(self) {
                if (isPlaying && progressReferenceTime > 0.0) {
                    elapsedPlaybackTime += PowerPlayCurrentTime() - progressReferenceTime;
                    if (trackDuration > 0.0 && elapsedPlaybackTime > trackDuration) {
                        elapsedPlaybackTime = trackDuration;
                    }
                }
                progressResumeOffset = elapsedPlaybackTime;
                resumeProgressPending = YES;
                progressIsRelative = NO;
                progressReferenceTime = 0.0;
                isPlaying = NO;
                NSLog(@"RAOP: sender paused playback at %.1f seconds", elapsedPlaybackTime);
            }
            [audioPlayer stop];
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
        } else if ([method isEqualToString:@"TEARDOWN"]) {
            isPlaying = NO;
            isSetupComplete = NO;
            rtpSessionReady = NO;
            rtspSessionEstablished = NO;
            [audioPlayer stop];
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
        } else if ([method isEqualToString:@"FLUSH"]) {
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            contentType = @"text/parameters";
            responseBody = @"";
        } else if ([method isEqualToString:@"SET_PARAMETER"]) {
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            if ([requestContentType hasPrefix:@"application/x-dmap-tagged"]) {
                NSDictionary *parsedMetadata = [metadataParser parseDMAPData:requestBodyData];
                [self applyParsedMetadata:parsedMetadata];
                responseBody = @"";
            } else if ([requestContentType hasPrefix:@"image/"]) {
                if ([requestBodyData length] > 0) {
                    NSDictionary *artwork = [NSDictionary dictionaryWithObject:requestBodyData
                                                                        forKey:@"coverArtData"];
                    [self applyParsedMetadata:artwork];
                    NSLog(@"RAOP: received cover art (%lu bytes, %@)",
                          (unsigned long)[requestBodyData length], requestContentType);
                }
                responseBody = @"";
            } else {
                contentType = @"text/parameters";
                if ([requestParameter length] > 0) {
                    BOOL handledParameter = NO;
                    NSArray *parameterLines = [requestParameter componentsSeparatedByString:@"\n"];
                    NSUInteger parameterIndex;
                    for (parameterIndex = 0; parameterIndex < [parameterLines count]; parameterIndex++) {
                        NSString *parameterLine = [[parameterLines objectAtIndex:parameterIndex]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        NSRange colon = [parameterLine rangeOfString:@":"];
                        if (colon.location == NSNotFound) {
                            continue;
                        }
                        NSString *parameterName = [[parameterLine substringToIndex:colon.location] lowercaseString];
                        NSString *parameterValue = [[parameterLine substringFromIndex:colon.location + 1]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

                        if ([parameterName isEqualToString:@"volume"]) {
                            handledParameter = YES;
                            NSScanner *scanner = [NSScanner scannerWithString:parameterValue];
                            float parsedVolume = 0.0f;
                            if ([scanner scanFloat:&parsedVolume]) {
                                float newVolume = PowerPlayLinearGainFromDecibels(parsedVolume);
                                BOOL volumeChanged;
                                @synchronized(self) {
                                    volumeChanged = fabsf(volume - newVolume) > 0.0001f;
                                    volume = newVolume;
                                }
                                [audioPlayer setVolume:newVolume];
                                if (volumeChanged) {
                                    [[NSNotificationCenter defaultCenter] postNotificationName:PowerPlayVolumeDidChangeNotification
                                                                                        object:self];
                                }
                            }
                            responseBody = [NSString stringWithFormat:@"volume: %.3f\r\n",
                                PowerPlayDecibelsFromLinearGain([self volumeValue])];
                        } else if ([parameterName isEqualToString:@"progress"]) {
                            handledParameter = YES;
                            NSArray *timestamps = [parameterValue componentsSeparatedByString:@"/"];
                            uint32_t startTimestamp = 0;
                            uint32_t currentTimestamp = 0;
                            uint32_t endTimestamp = 0;
                            if ([timestamps count] == 3 &&
                                PowerPlayParseUInt32([[timestamps objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], &startTimestamp) &&
                                PowerPlayParseUInt32([[timestamps objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], &currentTimestamp) &&
                                PowerPlayParseUInt32([[timestamps objectAtIndex:2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], &endTimestamp)) {
                                uint32_t durationFrames = endTimestamp - startTimestamp;
                                uint32_t elapsedFrames = currentTimestamp - startTimestamp;
                                if (durationFrames > 0 && elapsedFrames <= durationFrames) {
                                    double newDuration = (double)durationFrames / 44100.0;
                                    double newElapsed = (double)elapsedFrames / 44100.0;
                                    BOOL progressChanged;
                                    @synchronized(self) {
                                        double now = PowerPlayCurrentTime();
                                        BOOL audioRecentlyActive = lastAudioPacketTime == 0.0 ||
                                            now - lastAudioPacketTime <= 1.5;
                                        BOOL playbackActive = isPlaying && audioRecentlyActive;
                                        if (playbackActive) {
                                            if (resumeProgressPending) {
                                                double previousProgressElapsed =
                                                    (double)(lastProgressCurrentTimestamp - lastProgressStartTimestamp) / 44100.0;
                                                progressIsRelative = !hasProgressTimestamp ||
                                                    startTimestamp != lastProgressStartTimestamp ||
                                                    newElapsed + 0.5 < previousProgressElapsed ||
                                                    newElapsed + 0.5 < progressResumeOffset;
                                                resumeProgressPending = NO;
                                            }
                                            if (progressIsRelative) {
                                                newElapsed += progressResumeOffset;
                                            }
                                        }
                                        double displayElapsed = playbackActive ? newElapsed : elapsedPlaybackTime;
                                        progressChanged = fabs(elapsedPlaybackTime - displayElapsed) >= 0.05 ||
                                                          fabs(trackDuration - newDuration) >= 0.05;
                                        if (playbackActive) {
                                            elapsedPlaybackTime = newElapsed;
                                            progressReferenceTime = now;
                                            lastProgressStartTimestamp = startTimestamp;
                                            lastProgressCurrentTimestamp = currentTimestamp;
                                            hasProgressTimestamp = YES;
                                        }
                                        trackDuration = newDuration;
                                    }
                                    if (progressChanged) {
                                        NSLog(@"RAOP: progress %.1f / %.1f seconds",
                                              newElapsed, newDuration);
                                        [[NSNotificationCenter defaultCenter] postNotificationName:PowerPlayPlaybackProgressDidChangeNotification
                                                                                            object:self];
                                    }
                                } else {
                                    NSLog(@"RAOP: ignored progress with invalid duration/current range: %@", parameterValue);
                                }
                            } else {
                                NSLog(@"RAOP: ignored malformed progress tuple: %@", parameterValue);
                            }
                        }
                    }
                    if (!handledParameter) {
                        responseBody = [NSString stringWithFormat:@"%@\r\n", requestParameter];
                    } else if (responseBody == nil) {
                        responseBody = @"";
                    }
                } else {
                    responseBody = @"";
                }
            }
        } else if ([method isEqualToString:@"GET_PARAMETER"]) {
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            contentType = @"text/parameters";
            if ([requestParameter length] > 0) {
                if ([requestParameter rangeOfString:@"volume" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    responseBody = [NSString stringWithFormat:@"volume: %.3f\r\n",
                        PowerPlayDecibelsFromLinearGain([self volumeValue])];
                } else if ([requestParameter rangeOfString:@"position" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    responseBody = @"position: 0.000000\r\n";
                } else {
                    responseBody = [NSString stringWithFormat:@"%@: %@\r\n", requestParameter, @""];
                }
            } else {
                responseBody = [NSString stringWithFormat:@"volume: %.3f\r\n",
                    PowerPlayDecibelsFromLinearGain([self volumeValue])];
            }
        } else {
            status = @"501 Not Implemented";
        }

        NSMutableString *headerBlock = [NSMutableString stringWithString:responseHeaders];
        if (contentType != nil || responseBody != nil) {
            NSUInteger bodyLength = responseBody == nil ? 0 : [responseBody lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (contentType != nil) {
                [headerBlock appendFormat:@"Content-Type: %@\r\n", contentType];
            }
            [headerBlock appendFormat:@"Content-Length: %lu\r\n", (unsigned long)bodyLength];
        }

        NSString *response = [NSString stringWithFormat:
            @"RTSP/1.0 %@\r\nCSeq: %@\r\n%@Server: PowerPlay/1.0\r\n\r\n%@",
            status, cseq, headerBlock, responseBody == nil ? @"" : responseBody];
        PowerPlayLogAndSendRTSPResponse(incomingSocket, response);

        if ([method isEqualToString:@"TEARDOWN"] ||
            [status hasPrefix:@"455"] || [status hasPrefix:@"461"] || [status hasPrefix:@"500"]) {
            break;
        }
    }

    [self resetSessionAfterDisconnect];
}

- (void)connectToService:(NSNetService *)service {
    if (service == nil) {
        return;
    }

    [resolvedService release];
    resolvedService = [service retain];
    [resolvedService setDelegate:self];
    [resolvedService resolveWithTimeout:8.0];
}

- (NSString *)addressStringFromData:(NSData *)addressData {
    if (addressData == nil || [addressData length] == 0) {
        return nil;
    }

    const struct sockaddr *sockaddrPtr = (const struct sockaddr *)[addressData bytes];
    if (sockaddrPtr == NULL) {
        return nil;
    }

    char ipBuffer[INET6_ADDRSTRLEN];
    memset(ipBuffer, 0, sizeof(ipBuffer));

    if (sockaddrPtr->sa_family == AF_INET) {
        const struct sockaddr_in *addr4 = (const struct sockaddr_in *)sockaddrPtr;
        if (inet_ntop(AF_INET, &(addr4->sin_addr), ipBuffer, sizeof(ipBuffer)) == NULL) {
            return nil;
        }
        return [NSString stringWithCString:ipBuffer encoding:NSUTF8StringEncoding];
    }

    if (sockaddrPtr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6 *)sockaddrPtr;
        if (inet_ntop(AF_INET6, &(addr6->sin6_addr), ipBuffer, sizeof(ipBuffer)) == NULL) {
            return nil;
        }
        return [NSString stringWithCString:ipBuffer encoding:NSUTF8StringEncoding];
    }

    return nil;
}

- (BOOL)openControlSocket {
    if (hostAddress == nil || [hostAddress length] == 0) {
        return NO;
    }

    if (controlSocket >= 0) {
        close(controlSocket);
        controlSocket = -1;
    }

    struct sockaddr_in serverAddress;
    memset(&serverAddress, 0, sizeof(serverAddress));
    serverAddress.sin_family = AF_INET;
    serverAddress.sin_port = htons((unsigned short)controlPort);
    if (inet_pton(AF_INET, [hostAddress UTF8String], &serverAddress.sin_addr) != 1) {
        return NO;
    }

    controlSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (controlSocket < 0) {
        return NO;
    }

    if (connect(controlSocket, (struct sockaddr *)&serverAddress, sizeof(serverAddress)) != 0) {
        close(controlSocket);
        controlSocket = -1;
        return NO;
    }

    return YES;
}

- (BOOL)openUDPListenerOnPort:(NSInteger)port socket:(int *)socketHandle {
    if (socketHandle == NULL || port <= 0) {
        return NO;
    }

    int udpSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (udpSocket < 0) {
        *socketHandle = -1;
        return NO;
    }

    int reuse = 1;
    setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in localAddress;
    memset(&localAddress, 0, sizeof(localAddress));
    localAddress.sin_family = AF_INET;
    localAddress.sin_port = htons((unsigned short)port);
    localAddress.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(udpSocket, (struct sockaddr *)&localAddress, sizeof(localAddress)) != 0) {
        close(udpSocket);
        *socketHandle = -1;
        return NO;
    }

    *socketHandle = udpSocket;
    return YES;
}

- (void)beginRTSPSession {
    if (controlSocket < 0 || hostAddress == nil) {
        return;
    }

    rtspSessionEstablished = NO;
    rtpSessionReady = NO;
    isSetupComplete = NO;

    NSMutableDictionary *optionsHeaders = [NSMutableDictionary dictionary];
    [optionsHeaders setObject:@"*" forKey:@"Accept"];
    [self sendRTSPCommand:@"OPTIONS" path:@"/" headers:optionsHeaders body:nil];

    NSMutableDictionary *announceHeaders = [NSMutableDictionary dictionary];
    [announceHeaders setObject:@"text/plain" forKey:@"Content-Type"];
    [announceHeaders setObject:@"AppleAirPlay" forKey:@"X-Apple-Device-ID"];
    NSData *announceBody = [@"session=1\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    [self sendRTSPCommand:@"ANNOUNCE" path:@"/" headers:announceHeaders body:announceBody];

    if ([self openUDPListenerOnPort:audioPort socket:&audioSocket]) {
        [metadata setObject:[NSNumber numberWithInt:(int)audioPort] forKey:@"audio_port"];
    }

    if ([self openUDPListenerOnPort:timingPort socket:&timingSocket]) {
        [metadata setObject:[NSNumber numberWithInt:(int)timingPort] forKey:@"timing_port"];
    }

    [self setupRTPStreams];
    rtspSessionEstablished = YES;
}

- (void)closeControlSocket {
    if (controlSocket >= 0) {
        close(controlSocket);
        controlSocket = -1;
    }
}

- (BOOL)isConnected {
    BOOL hasIncomingSession;
    @synchronized(self) {
        hasIncomingSession = incomingSessionActive;
    }
    return hasIncomingSession || ((controlSocket >= 0) && (hostAddress != nil) && ([hostAddress length] > 0));
}

- (BOOL)isSessionReady {
    return rtspSessionEstablished && rtpSessionReady && isSetupComplete;
}

- (void)teardownSession {
    if (controlSocket >= 0) {
        [self sendRTSPCommand:@"TEARDOWN" path:@"/" headers:nil body:nil];
        close(controlSocket);
        controlSocket = -1;
    }

    if (audioSocket >= 0) {
        close(audioSocket);
        audioSocket = -1;
    }

    if (timingSocket >= 0) {
        close(timingSocket);
        timingSocket = -1;
    }
    if (rtpControlSocket >= 0) {
        close(rtpControlSocket);
        rtpControlSocket = -1;
    }

    rtspSessionEstablished = NO;
    rtpSessionReady = NO;
    isSetupComplete = NO;
    isPlaying = NO;
}

- (void)bindRTPTransportOnPort:(NSInteger)port socket:(int *)socketHandle {
    if (socketHandle == NULL || port <= 0) {
        return;
    }

    int udpSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (udpSocket < 0) {
        *socketHandle = -1;
        return;
    }

    int reuse = 1;
    setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in localAddress;
    memset(&localAddress, 0, sizeof(localAddress));
    localAddress.sin_family = AF_INET;
    localAddress.sin_port = htons((unsigned short)port);
    localAddress.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(udpSocket, (struct sockaddr *)&localAddress, sizeof(localAddress)) != 0) {
        close(udpSocket);
        *socketHandle = -1;
        return;
    }

    *socketHandle = udpSocket;
}

- (BOOL)parseTransportHeader:(NSString *)transportHeader {
    if (transportHeader == nil || [transportHeader length] == 0) {
        return NO;
    }

    BOOL foundAnyPort = NO;
    NSArray *parts = [transportHeader componentsSeparatedByString:@";"];
    NSUInteger i;
    for (i = 0; i < [parts count]; i++) {
        NSString *part = [[parts objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([part length] == 0) {
            continue;
        }

        NSRange equalsRange = [part rangeOfString:@"="];
        if (equalsRange.location == NSNotFound) {
            continue;
        }

        NSString *key = [[part substringToIndex:equalsRange.location] lowercaseString];
        NSString *value = [part substringFromIndex:(equalsRange.location + 1)];
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([key isEqualToString:@"server_port"]) {
            NSArray *ports = [value componentsSeparatedByString:@"-"];
            if ([ports count] > 0) {
                NSString *firstPortString = [[ports objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSInteger portValue = [firstPortString intValue];
                if (portValue > 0) {
                    audioPort = portValue;
                    foundAnyPort = YES;
                }
            }
        } else if ([key isEqualToString:@"control_port"]) {
            NSInteger portValue = [value intValue];
            if (portValue > 0) {
                controlPort = portValue;
                foundAnyPort = YES;
            }
        } else if ([key isEqualToString:@"timing_port"]) {
            NSInteger portValue = [value intValue];
            if (portValue > 0) {
                timingPort = portValue;
                foundAnyPort = YES;
            }
        }
    }

    if (!foundAnyPort) {
        NSRange serverPortRange = [transportHeader rangeOfString:@"server_port="];
        if (serverPortRange.location != NSNotFound) {
            NSString *tail = [transportHeader substringFromIndex:(serverPortRange.location + serverPortRange.length)];
            NSRange comma = [tail rangeOfString:@","];
            if (comma.location != NSNotFound) {
                tail = [tail substringToIndex:comma.location];
            }
            NSString *firstPort = [[tail componentsSeparatedByString:@"-"] objectAtIndex:0];
            NSInteger serverPort = [firstPort intValue];
            if (serverPort > 0) {
                audioPort = serverPort;
                foundAnyPort = YES;
            }
        }
    }

    if (!foundAnyPort) {
        NSRange controlPortRange = [transportHeader rangeOfString:@"control_port="];
        if (controlPortRange.location != NSNotFound) {
            NSString *tail = [transportHeader substringFromIndex:(controlPortRange.location + controlPortRange.length)];
            NSRange comma = [tail rangeOfString:@","];
            if (comma.location != NSNotFound) {
                tail = [tail substringToIndex:comma.location];
            }
            NSInteger controlPortValue = [tail intValue];
            if (controlPortValue > 0) {
                controlPort = controlPortValue;
                foundAnyPort = YES;
            }
        }
    }

    return foundAnyPort || [transportHeader length] > 0;
}

- (void)setupRTPStreams {
    if (hostAddress == nil || [hostAddress length] == 0) {
        return;
    }

    [self bindRTPTransportOnPort:audioPort socket:&audioSocket];
    [self bindRTPTransportOnPort:timingPort socket:&timingSocket];

    if (audioSocket >= 0 || timingSocket >= 0) {
        rtpSessionReady = YES;
        [metadata setObject:[NSNumber numberWithBool:YES] forKey:@"rtp_session_ready"];
    }

    [self readAudioPackets];
    [self readTimingPackets];
}

- (void)receiveAudioPackets {
    NSAutoreleasePool *threadPool = [[NSAutoreleasePool alloc] init];
    unsigned long packetCount = 0;
    unsigned long invalidPacketCount = 0;
    unsigned long decryptFailureCount = 0;
    unsigned long decryptedPacketCount = 0;
    unsigned long decodedPacketCount = 0;
    uint64_t lastAudioPacketMicros = 0;
    BOOL loggedAudioSilence = NO;
    NSLog(@"RAOP: audio RTP receiver started");

    while (acceptingRTSP) {
        int socketHandle = audioSocket;
        if (socketHandle < 0 || !isSetupComplete) {
            usleep(100000);
            continue;
        }

        fd_set readSockets;
        FD_ZERO(&readSockets);
        FD_SET(socketHandle, &readSockets);
        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 250000;

        int ready = select(socketHandle + 1, &readSockets, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (!acceptingRTSP) {
                break;
            }
            if (socketHandle != audioSocket || !isSetupComplete) {
                continue;
            }
            NSLog(@"RAOP: audio RTP select failed (%d)", errno);
            usleep(100000);
            continue;
        }
        if (ready == 0) {
            if (isPlaying && isSetupComplete && lastAudioPacketMicros != 0 && !loggedAudioSilence) {
                struct timeval now;
                gettimeofday(&now, NULL);
                uint64_t nowMicros = (uint64_t)now.tv_sec * 1000000ULL + (uint64_t)now.tv_usec;
                if (nowMicros - lastAudioPacketMicros >= 3000000ULL) {
                    NSLog(@"RAOP: no audio RTP datagrams for 3 seconds (received=%lu decrypted=%lu decoded=%lu)",
                          packetCount, decryptedPacketCount, decodedPacketCount);
                    loggedAudioSilence = YES;
                }
            }
            continue;
        }
        if (!FD_ISSET(socketHandle, &readSockets) ||
            socketHandle != audioSocket || !isSetupComplete) {
            continue;
        }

        char packetBuffer[65536];
        struct sockaddr_in sender;
        socklen_t senderLength = sizeof(sender);
        ssize_t received = recvfrom(socketHandle, packetBuffer, sizeof(packetBuffer), 0,
                                    (struct sockaddr *)&sender, &senderLength);
        if (received > 0) {
            packetCount++;
            struct timeval packetTime;
            gettimeofday(&packetTime, NULL);
            lastAudioPacketMicros = (uint64_t)packetTime.tv_sec * 1000000ULL + (uint64_t)packetTime.tv_usec;
            double packetTimeSeconds = (double)packetTime.tv_sec + ((double)packetTime.tv_usec / 1000000.0);
            @synchronized(self) {
                if (isPlaying && lastAudioPacketTime > 0.0 &&
                    packetTimeSeconds - lastAudioPacketTime > 1.5) {
                    double activeUntil = lastAudioPacketTime + 1.5;
                    if (progressReferenceTime > 0.0 && activeUntil > progressReferenceTime) {
                        elapsedPlaybackTime += activeUntil - progressReferenceTime;
                    }
                    progressReferenceTime = packetTimeSeconds;
                    NSLog(@"RAOP: audio RTP resumed after silence");
                }
                lastAudioPacketTime = packetTimeSeconds;
            }
            loggedAudioSilence = NO;
            NSData *packet = [NSData dataWithBytes:(void *)packetBuffer
                                             length:(NSUInteger)received];
            NSRange payloadRange;
            BOOL validRTPHeader = [self validateRTPPacket:packet];
            BOOL validPayloadLayout = validRTPHeader && PowerPlayRTPPayloadRange(packet, &payloadRange);
            if (!validRTPHeader || !validPayloadLayout) {
                invalidPacketCount++;
                if (invalidPacketCount == 1) {
                    const unsigned char *bytes = [packet bytes];
                    unsigned int version = [packet length] > 0 ? (bytes[0] >> 6) & 0x03 : 0;
                    unsigned int payloadType = [packet length] > 1 ? bytes[1] & 0x7F : 0;
                    unsigned int sequence = [packet length] > 3 ? ((unsigned int)bytes[2] << 8) | bytes[3] : 0;
                    NSLog(@"RAOP: rejected first RTP audio datagram (%ld bytes; header-valid=%d payload-layout-valid=%d version=%u PT=%u seq=%u)",
                          (long)received, validRTPHeader, validPayloadLayout,
                          version, payloadType, sequence);
                }
                continue;
            }

            NSData *key = nil;
            NSData *iv = nil;
            @synchronized(self) {
                key = [audioAESKey retain];
                iv = [audioAESIV retain];
            }
            NSData *decryptedPayload = PowerPlayDecryptRTPPayload(packet, payloadRange, key, iv);
            [key release];
            [iv release];
            if (decryptedPayload == nil) {
                decryptFailureCount++;
                if (decryptFailureCount == 1) {
                    NSLog(@"RAOP: could not decrypt first RTP payload (%lu bytes)",
                          (unsigned long)payloadRange.length);
                }
                continue;
            }

            decryptedPacketCount++;
            if (decryptedPacketCount == 1 || decryptedPacketCount % 100 == 0) {
                const unsigned char *bytes = [packet bytes];
                unsigned int payloadType = bytes[1] & 0x7F;
                unsigned int sequenceNumber = ((unsigned int)bytes[2] << 8) | bytes[3];
                NSLog(@"RAOP: decrypted %lu RTP audio payloads; PT=%u seq=%u payload=%lu bytes from %s:%u",
                      decryptedPacketCount, payloadType, sequenceNumber,
                      (unsigned long)payloadRange.length, inet_ntoa(sender.sin_addr),
                      (unsigned int)ntohs(sender.sin_port));
            }

            NSData *pcmData = [alacDecoder decodePacket:decryptedPayload];
            if (pcmData == nil || [pcmData length] == 0) {
                continue;
            }
            decodedPacketCount++;
            [audioPlayer enqueuePCMData:pcmData];
            if (decodedPacketCount == 1 || decodedPacketCount % 100 == 0) {
                NSLog(@"RAOP: decoded %lu ALAC packets to %lu PCM bytes",
                      decodedPacketCount, (unsigned long)[pcmData length]);
            }
        } else if (received < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            NSLog(@"RAOP: audio RTP receive failed (%d)", errno);
        }
    }

    NSLog(@"RAOP: audio RTP receiver stopped after %lu datagrams", packetCount);
    [threadPool drain];
}

- (void)receiveControlPackets {
    NSAutoreleasePool *threadPool = [[NSAutoreleasePool alloc] init];
    unsigned long packetCount = 0;
    NSLog(@"RAOP: RTP control receiver started");

    while (acceptingRTSP) {
        int socketHandle = rtpControlSocket;
        if (socketHandle < 0 || !isSetupComplete) {
            usleep(100000);
            continue;
        }

        fd_set readSockets;
        FD_ZERO(&readSockets);
        FD_SET(socketHandle, &readSockets);
        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 250000;
        int ready = select(socketHandle + 1, &readSockets, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (!acceptingRTSP) {
                break;
            }
            if (socketHandle == rtpControlSocket && isSetupComplete) {
                NSLog(@"RAOP: RTP control select failed (%d)", errno);
                usleep(100000);
            }
            continue;
        }
        if (ready == 0 || !FD_ISSET(socketHandle, &readSockets) ||
            socketHandle != rtpControlSocket || !isSetupComplete) {
            continue;
        }

        unsigned char packet[2048];
        struct sockaddr_in sender;
        socklen_t senderLength = sizeof(sender);
        ssize_t received = recvfrom(socketHandle, packet, sizeof(packet), 0,
                                    (struct sockaddr *)&sender, &senderLength);
        if (received > 0) {
            packetCount++;
            if (packetCount == 1 || packetCount % 100 == 0) {
                NSLog(@"RAOP: received %lu RTP control packets; latest type=0x%02x length=%ld",
                      packetCount, received > 1 ? packet[1] : 0, (long)received);
            }
        } else if (received < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            NSLog(@"RAOP: RTP control receive failed (%d)", errno);
        }
    }

    NSLog(@"RAOP: RTP control receiver stopped after %lu packets", packetCount);
    [threadPool drain];
}

- (void)receiveTimingPackets {
    NSAutoreleasePool *threadPool = [[NSAutoreleasePool alloc] init];
    unsigned long inboundRequestCount = 0;
    unsigned long outboundRequestCount = 0;
    unsigned long replyCount = 0;
    NSLog(@"RAOP: RTP timing responder started");
    NSInteger activeSenderTimingPort = 0;
    uint16_t sequenceNumber = 0;
    uint64_t nextRequestTime = 0;

    while (acceptingRTSP) {
        int socketHandle = timingSocket;
        if (socketHandle < 0 || !isSetupComplete) {
            usleep(100000);
            continue;
        }

        NSInteger remoteTimingPort = senderTimingPort;
        if (remoteTimingPort != activeSenderTimingPort) {
            activeSenderTimingPort = remoteTimingPort;
            sequenceNumber = 0;
            nextRequestTime = 0;
        }

        struct timeval now;
        gettimeofday(&now, NULL);
        uint64_t nowMicros = (uint64_t)now.tv_sec * 1000000ULL + (uint64_t)now.tv_usec;
        if (remoteTimingPort > 0 && nowMicros >= nextRequestTime) {
            struct sockaddr_in remoteAddress;
            memset(&remoteAddress, 0, sizeof(remoteAddress));
            remoteAddress.sin_family = AF_INET;
            remoteAddress.sin_port = htons((unsigned short)remoteTimingPort);
            if (hostAddress != nil &&
                inet_pton(AF_INET, [hostAddress UTF8String], &remoteAddress.sin_addr) == 1) {
                unsigned char timingRequest[32];
                memset(timingRequest, 0, sizeof(timingRequest));
                timingRequest[0] = 0x80;
                timingRequest[1] = 0xD2;
                uint16_t networkSequence = htons(sequenceNumber++);
                memcpy(timingRequest + 2, &networkSequence, sizeof(networkSequence));
                ssize_t sent = sendto(socketHandle, timingRequest, sizeof(timingRequest), 0,
                                      (struct sockaddr *)&remoteAddress, sizeof(remoteAddress));
                if (sent == (ssize_t)sizeof(timingRequest)) {
                    outboundRequestCount++;
                    if (outboundRequestCount == 1 || outboundRequestCount % 100 == 0) {
                        NSLog(@"RAOP: sent %lu RTP timing requests to %s:%ld",
                              outboundRequestCount, [hostAddress UTF8String], (long)remoteTimingPort);
                    }
                } else if (sent < 0) {
                    NSLog(@"RAOP: RTP timing request failed (%d)", errno);
                }
            }
            uint64_t intervalMicros = outboundRequestCount < 3 ? 300000ULL : 3000000ULL;
            nextRequestTime = nowMicros + intervalMicros;
        }

        fd_set readSockets;
        FD_ZERO(&readSockets);
        FD_SET(socketHandle, &readSockets);
        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 250000;
        int ready = select(socketHandle + 1, &readSockets, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (!acceptingRTSP) {
                break;
            }
            if (socketHandle == timingSocket && isSetupComplete) {
                NSLog(@"RAOP: RTP timing select failed (%d)", errno);
                usleep(100000);
            }
            continue;
        }
        if (ready == 0 || !FD_ISSET(socketHandle, &readSockets) ||
            socketHandle != timingSocket || !isSetupComplete) {
            continue;
        }

        unsigned char request[2048];
        struct sockaddr_in sender;
        socklen_t senderLength = sizeof(sender);
        ssize_t received = recvfrom(socketHandle, request, sizeof(request), 0,
                                    (struct sockaddr *)&sender, &senderLength);
        if (received < 0) {
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                NSLog(@"RAOP: RTP timing receive failed (%d)", errno);
            }
            continue;
        }

        if (received < 32 || (request[0] & 0xC0) != 0x80 || request[1] != 0xD2) {
            if (received >= 2 && (request[0] & 0xC0) == 0x80 && request[1] == 0xD3) {
                replyCount++;
                if (replyCount == 1 || replyCount % 100 == 0) {
                    NSLog(@"RAOP: received %lu RTP timing replies", replyCount);
                }
            } else {
                inboundRequestCount++;
                if (inboundRequestCount == 1) {
                    NSLog(@"RAOP: ignored non-timing packet on timing port (%ld bytes, type=0x%02x)",
                          (long)received, received > 1 ? request[1] : 0);
                }
            }
            continue;
        }

        unsigned char response[32];
        memset(response, 0, sizeof(response));
        response[0] = 0x80;
        response[1] = 0xD3;
        memcpy(response + 2, request + 2, 2);
        memcpy(response + 8, request + 24, 8);
        PowerPlayWriteNTPTime(response + 16);
        PowerPlayWriteNTPTime(response + 24);

        ssize_t sent = sendto(socketHandle, response, sizeof(response), 0,
                              (struct sockaddr *)&sender, senderLength);
        if (sent == (ssize_t)sizeof(response)) {
            inboundRequestCount++;
            if (inboundRequestCount == 1 || inboundRequestCount % 100 == 0) {
                NSLog(@"RAOP: replied to %lu inbound RTP timing requests", inboundRequestCount);
            }
        } else if (sent < 0) {
            NSLog(@"RAOP: RTP timing reply failed (%d)", errno);
        }
    }

        NSLog(@"RAOP: RTP timing worker stopped after %lu outbound requests, %lu replies, and %lu inbound requests",
                    outboundRequestCount, replyCount, inboundRequestCount);
    [threadPool drain];
}

- (void)readAudioPackets {
    if (audioSocket < 0) {
        return;
    }

    // Skeleton: read RTP packets and send them to the decoder. The actual implementation would
    // need to parse the RTP header, extract the ALAC payload, reassemble fragmented packets, and
    // hand the frame(s) off to the decoder.
    char packetBuffer[4096];
    struct sockaddr_in sender;
    socklen_t senderLen = sizeof(sender);
    ssize_t received = recvfrom(audioSocket, packetBuffer, sizeof(packetBuffer) - 1, 0,
                               (struct sockaddr *)&sender, &senderLen);
    if (received > 0) {
        NSData *packetData = [NSData dataWithBytes:packetBuffer length:(NSUInteger)received];
        [self handleRTPPacket:packetData];
    }
}

- (void)readTimingPackets {
    if (timingSocket < 0) {
        return;
    }

    // Timing packets carry sync and sequencing data used to keep audio in sync with RTCP-style
    // timing. This stack simply ensures the socket exists and that the app is ready to parse it.
    char packetBuffer[2048];
    struct sockaddr_in sender;
    socklen_t senderLen = sizeof(sender);
    ssize_t received = recvfrom(timingSocket, packetBuffer, sizeof(packetBuffer) - 1, 0,
                               (struct sockaddr *)&sender, &senderLen);
    if (received > 0) {
        NSData *packetData = [NSData dataWithBytes:packetBuffer length:(NSUInteger)received];
        [self handleRTPPacket:packetData];
    }
}

- (void)handleRTPPacket:(NSData *)packet {
    if (packet == nil || [packet length] < 12) {
        return;
    }

    if (![self validateRTPPacket:packet]) {
        return;
    }

    const unsigned char *bytes = [packet bytes];
    unsigned int version = (bytes[0] >> 6) & 0x03;
    unsigned int marker = (bytes[1] >> 7) & 0x01;
    unsigned int payloadType = bytes[1] & 0x7F;
    unsigned int sequenceNumber = ((unsigned int)bytes[2] << 8) | bytes[3];
    unsigned int timestamp = ((unsigned int)bytes[4] << 24) |
                            ((unsigned int)bytes[5] << 16) |
                            ((unsigned int)bytes[6] << 8) |
                            ((unsigned int)bytes[7]);

    // This is where a real AirPlay receiver would validate the RTP version, identify the codec
    // payload type, and strip the RTP header before handing the ALAC payload to the decoder.
    if (version != 2) {
        return;
    }

    [metadata setObject:[NSNumber numberWithUnsignedInt:sequenceNumber] forKey:@"last_rtp_sequence"];
    [metadata setObject:[NSNumber numberWithUnsignedInt:timestamp] forKey:@"last_rtp_timestamp"];
    [metadata setObject:[NSNumber numberWithUnsignedInt:marker] forKey:@"last_rtp_marker"];
    [metadata setObject:[NSNumber numberWithUnsignedInt:payloadType] forKey:@"last_rtp_payload_type"];

    if (payloadType == 96 || payloadType == 97 || payloadType == 98 || payloadType == 99) {
        NSData *payload = [packet subdataWithRange:NSMakeRange(12, [packet length] - 12)];
        if (payload != nil && [payload length] > 0) {
            NSData *decodedPCM = [alacDecoder decodePacket:payload];
            if (decodedPCM != nil) {
                [metadata setObject:decodedPCM forKey:@"last_pcm_frame"];
                if (audioPlayer != nil) {
                    [audioPlayer enqueuePCMData:decodedPCM];
                }
            }
        }
    }
}

- (void)handleMetadataPacket:(NSData *)packet {
    if (packet == nil || [packet length] == 0) {
        return;
    }

    NSDictionary *parsedMetadata = [metadataParser parsePlistData:packet];
    if ([parsedMetadata count] > 0) {
        [self applyParsedMetadata:parsedMetadata];
    }

    NSString *packetText = [[[NSString alloc] initWithData:packet encoding:NSUTF8StringEncoding] autorelease];
    if (packetText != nil && [packetText length] > 0) {
        [metadata setObject:packetText forKey:@"raw_metadata"];
    }
}

- (void)parseMetadataFromPlistData:(NSData *)plistData {
    if (plistData == nil || [plistData length] == 0) {
        return;
    }

    NSDictionary *parsed = [metadataParser parsePlistData:plistData];
    [self applyParsedMetadata:parsed];
}

- (void)applyParsedMetadata:(NSDictionary *)parsedMetadata {
    if (parsedMetadata == nil || [parsedMetadata count] == 0) {
        return;
    }

    BOOL changed = NO;
    BOOL titleChanged = NO;
    NSString *newTitle = [parsedMetadata objectForKey:@"title"];
    NSString *newArtist = [parsedMetadata objectForKey:@"artist"];
    NSString *newAlbum = [parsedMetadata objectForKey:@"album"];
    NSData *newCoverData = [parsedMetadata objectForKey:@"coverArtData"];
    NSNumber *newTrackDuration = [parsedMetadata objectForKey:@"duration"];

    @synchronized(self) {
        BOOL sameTitleChangedTrack = [newTitle isKindOfClass:[NSString class]] &&
            [newTitle length] > 0 && [newTitle isEqualToString:trackName] &&
            (([newArtist isKindOfClass:[NSString class]] && [newArtist length] > 0 &&
              [artistName length] > 0 && ![newArtist isEqualToString:artistName]) ||
             ([newAlbum isKindOfClass:[NSString class]] && [newAlbum length] > 0 &&
              [albumName length] > 0 && ![newAlbum isEqualToString:albumName]));
        if (sameTitleChangedTrack) {
            [coverArtData release];
            coverArtData = nil;
            changed = YES;
        }
        if ([newTitle isKindOfClass:[NSString class]] && [newTitle length] > 0 &&
            ![newTitle isEqualToString:currentTitle]) {
            BOOL replacingExistingTrack = [trackName length] > 0;
            [trackName release];
            trackName = [newTitle copy];
            [currentTitle release];
            currentTitle = [newTitle copy];
            changed = YES;
            titleChanged = YES;
            if (replacingExistingTrack) {
                [coverArtData release];
                coverArtData = nil;
            }
            elapsedPlaybackTime = 0.0;
            trackDuration = 0.0;
            progressResumeOffset = 0.0;
            lastProgressStartTimestamp = 0;
            lastProgressCurrentTimestamp = 0;
            hasProgressTimestamp = NO;
            resumeProgressPending = NO;
            progressIsRelative = NO;
            progressReferenceTime = isPlaying ? PowerPlayCurrentTime() : 0.0;
        }
        if ([newTrackDuration respondsToSelector:@selector(doubleValue)] &&
            [newTrackDuration doubleValue] > 0.0 &&
            fabs(trackDuration - [newTrackDuration doubleValue]) >= 0.05) {
            trackDuration = [newTrackDuration doubleValue];
            changed = YES;
            NSLog(@"RAOP: track duration from metadata %.1f seconds", trackDuration);
        }
        if ([newArtist isKindOfClass:[NSString class]] && [newArtist length] > 0 &&
            ![newArtist isEqualToString:artistName]) {
            [artistName release];
            artistName = [newArtist copy];
            changed = YES;
        }
        if (titleChanged && (![newArtist isKindOfClass:[NSString class]] || [newArtist length] == 0) &&
            artistName != nil) {
            [artistName release];
            artistName = nil;
            changed = YES;
        }
        if ([newAlbum isKindOfClass:[NSString class]] && [newAlbum length] > 0 &&
            ![newAlbum isEqualToString:albumName]) {
            [albumName release];
            albumName = [newAlbum copy];
            changed = YES;
        }
        if (titleChanged && (![newAlbum isKindOfClass:[NSString class]] || [newAlbum length] == 0) &&
            albumName != nil) {
            [albumName release];
            albumName = nil;
            changed = YES;
        }
        if ([newCoverData isKindOfClass:[NSData class]] && [newCoverData length] > 0 &&
            ![newCoverData isEqualToData:coverArtData]) {
            [coverArtData release];
            coverArtData = [newCoverData copy];
            changed = YES;
        }
        [metadata addEntriesFromDictionary:parsedMetadata];
    }

    if (titleChanged) {
        [self notifyTrackChangeIfNeeded];
    }
    if (changed) {
        [self notifyMetadataDidChange];
    }
}

- (void)notifyMetadataDidChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:PowerPlayMetadataDidChangeNotification
                                                        object:self];
}

- (void)notifyTrackChangeIfNeeded {
    if (currentTitle == nil || [currentTitle length] == 0) {
        return;
    }

    NSLog(@"Track changed: %@", currentTitle);
}

- (NSData *)readRTSPResponse {
    if (controlSocket < 0) {
        return nil;
    }

    fd_set readSet;
    struct timeval tv;
    FD_ZERO(&readSet);
    FD_SET(controlSocket, &readSet);
    tv.tv_sec = 2;
    tv.tv_usec = 0;

    if (select(controlSocket + 1, &readSet, NULL, NULL, &tv) <= 0) {
        return nil;
    }

    NSMutableData *buffer = [NSMutableData data];
    char chunk[2048];
    ssize_t length = 0;

    while ((length = recv(controlSocket, chunk, sizeof(chunk) - 1, 0)) > 0) {
        [buffer appendBytes:chunk length:(NSUInteger)length];
        FD_ZERO(&readSet);
        FD_SET(controlSocket, &readSet);
        tv.tv_sec = 0;
        tv.tv_usec = 50000;
        if (select(controlSocket + 1, &readSet, NULL, NULL, &tv) <= 0) {
            break;
        }
    }

    if ([buffer length] == 0) {
        return nil;
    }

    return buffer;
}

- (NSDictionary *)parseRTSPResponseData:(NSData *)responseData {
    if (responseData == nil || [responseData length] == 0) {
        return [NSDictionary dictionary];
    }

    NSString *responseString = [[[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] autorelease];
    if (responseString == nil) {
        return [NSDictionary dictionary];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [responseString componentsSeparatedByString:@"\r\n"];
    if ([lines count] > 0) {
        NSString *statusLine = [lines objectAtIndex:0];
        [result setObject:statusLine forKey:@"statusLine"];
    }

    NSUInteger idx;
    for (idx = 1; idx < [lines count]; idx++) {
        NSString *line = [lines objectAtIndex:idx];
        if ([line length] == 0) {
            break;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *value = [[line substringFromIndex:(colon.location + 1)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [result setObject:value forKey:key];
        }
    }

    if ([result objectForKey:@"Session"] != nil) {
        NSString *sessionValue = [result objectForKey:@"Session"];
        NSRange semicolon = [sessionValue rangeOfString:@";"];
        if (semicolon.location != NSNotFound) {
            sessionValue = [sessionValue substringToIndex:semicolon.location];
        }
        [result setObject:sessionValue forKey:@"Session"];
    }

    if ([result objectForKey:@"Transport"] != nil) {
        NSString *transportValue = [result objectForKey:@"Transport"];
        [self parseTransportHeader:transportValue];
    }

    return result;
}

- (NSDictionary *)parseNegotiationTrace:(NSData *)traceData {
    if (traceData == nil || [traceData length] == 0) {
        return [NSDictionary dictionary];
    }

    NSString *traceString = [[[NSString alloc] initWithData:traceData encoding:NSUTF8StringEncoding] autorelease];
    if (traceString == nil) {
        traceString = [[[NSString alloc] initWithData:traceData encoding:NSISOLatin1StringEncoding] autorelease];
    }
    if (traceString == nil) {
        return [NSDictionary dictionary];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result setObject:traceString forKey:@"rawTrace"];

    NSRange statusRange = [traceString rangeOfString:@"RTSP/1.0" options:NSCaseInsensitiveSearch];
    if (statusRange.location != NSNotFound) {
        NSString *statusLine = [[traceString substringFromIndex:statusRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [result setObject:statusLine forKey:@"statusLine"];
    }

    NSArray *lines = [traceString componentsSeparatedByString:@"\n"];
    NSUInteger i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line length] == 0) {
            continue;
        }

        NSRange colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound) {
            continue;
        }

        NSString *headerName = [[line substringToIndex:colonRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *headerValue = [[line substringFromIndex:(colonRange.location + 1)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([headerName caseInsensitiveCompare:@"Transport"] == NSOrderedSame) {
            [result setObject:headerValue forKey:@"Transport"];
            [self parseTransportHeader:headerValue];
        } else if ([headerName caseInsensitiveCompare:@"Session"] == NSOrderedSame) {
            NSString *sessionValue = headerValue;
            NSRange semicolon = [sessionValue rangeOfString:@";"];
            if (semicolon.location != NSNotFound) {
                sessionValue = [sessionValue substringToIndex:semicolon.location];
            }
            [result setObject:sessionValue forKey:@"Session"];
        } else if ([headerName caseInsensitiveCompare:@"CSeq"] == NSOrderedSame) {
            [result setObject:headerValue forKey:@"CSeq"];
        }
    }

    NSRange statusCodeRange = [traceString rangeOfString:@"200" options:NSCaseInsensitiveSearch];
    if (statusCodeRange.location != NSNotFound) {
        [result setObject:@"200" forKey:@"statusCode"];
    }

    NSRange methodRange = [traceString rangeOfString:@"SETUP" options:NSCaseInsensitiveSearch];
    if (methodRange.location == NSNotFound) {
        methodRange = [traceString rangeOfString:@"PLAY" options:NSCaseInsensitiveSearch];
    }
    if (methodRange.location == NSNotFound) {
        methodRange = [traceString rangeOfString:@"PAUSE" options:NSCaseInsensitiveSearch];
    }
    if (methodRange.location == NSNotFound) {
        methodRange = [traceString rangeOfString:@"ANNOUNCE" options:NSCaseInsensitiveSearch];
    }
    if (methodRange.location != NSNotFound) {
        [result setObject:@"RTSP" forKey:@"protocol"];
    }

    return result;
}

- (BOOL)validateRTSPTrace:(NSData *)traceData {
    if (traceData == nil || [traceData length] == 0) {
        return NO;
    }

    NSString *traceString = [[[NSString alloc] initWithData:traceData encoding:NSUTF8StringEncoding] autorelease];
    if (traceString == nil) {
        return NO;
    }

    BOOL hasRTSP = ([traceString rangeOfString:@"RTSP/1.0" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasStatusCode = ([traceString rangeOfString:@"200 OK" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                         ([traceString rangeOfString:@"200" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasMethod = ([traceString rangeOfString:@"OPTIONS" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     ([traceString rangeOfString:@"ANNOUNCE" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     ([traceString rangeOfString:@"SETUP" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     ([traceString rangeOfString:@"PLAY" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     ([traceString rangeOfString:@"PAUSE" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     ([traceString rangeOfString:@"TEARDOWN" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     ([traceString rangeOfString:@"GET_PARAMETER" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasTransport = ([traceString rangeOfString:@"Transport:" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                        ([traceString rangeOfString:@"transport=" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasSession = ([traceString rangeOfString:@"Session:" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                      ([traceString rangeOfString:@"session=" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasCSeq = ([traceString rangeOfString:@"CSeq:" options:NSCaseInsensitiveSearch].location != NSNotFound);

    if (hasRTSP && hasStatusCode && hasCSeq && hasTransport) {
        return YES;
    }

    if (hasRTSP && hasMethod && hasTransport && (hasSession || hasStatusCode)) {
        return YES;
    }

    return NO;
}

- (BOOL)validateRTPPacket:(NSData *)packet {
    if (packet == nil || [packet length] < 12) {
        return NO;
    }

    const unsigned char *bytes = [packet bytes];
    unsigned int version = (bytes[0] >> 6) & 0x03;
    if (version != 2) {
        return NO;
    }

    unsigned int payloadType = bytes[1] & 0x7F;
    BOOL isDynamicAudioPayload = (payloadType >= 96 && payloadType <= 127);
    BOOL isLegacyAudioPayload = (payloadType == 0 || payloadType == 1 || payloadType == 3 || payloadType == 8 || payloadType == 9 || payloadType == 11);
    if (!isDynamicAudioPayload && !isLegacyAudioPayload) {
        return NO;
    }

    return YES;
}

- (void)sendRTSPCommand:(NSString *)method path:(NSString *)path headers:(NSDictionary *)headers body:(NSData *)body {
    if (controlSocket < 0 || hostAddress == nil) {
        return;
    }

    NSString *requestPath = path;
    if (requestPath == nil || [requestPath length] == 0) {
        requestPath = @"/";
    }

    NSMutableString *request = [NSMutableString stringWithFormat:@"%@ %@ RTSP/1.0\r\n", method, requestPath];
    [request appendFormat:@"CSeq: %ld\r\n", (long)nextCSeq++];
    [request appendString:@"User-Agent: TigerAirPlayReceiver/1.0\r\n"];

    if (rtspSessionId != nil && [rtspSessionId length] > 0) {
        [request appendFormat:@"Session: %@\r\n", rtspSessionId];
    }

    if (headers != nil) {
        NSEnumerator *keyEnumerator = [headers keyEnumerator];
        NSString *key = nil;
        while ((key = [keyEnumerator nextObject]) != nil) {
            NSString *value = [headers objectForKey:key];
            if (value != nil) {
                [request appendFormat:@"%@: %@\r\n", key, value];
            }
        }
    }

    if (body != nil && [body length] > 0) {
        [request appendFormat:@"Content-Length: %lu\r\n\r\n", (unsigned long)[body length]];
        NSMutableData *fullPacket = [NSMutableData dataWithData:[request dataUsingEncoding:NSUTF8StringEncoding]];
        [fullPacket appendData:body];
        send(controlSocket, [fullPacket bytes], [fullPacket length], 0);
    } else {
        [request appendString:@"\r\n"];
        send(controlSocket, [request UTF8String], [request lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 0);
    }

    NSData *response = [self readRTSPResponse];
    NSDictionary *parsed = [self parseRTSPResponseData:response];
    NSString *sessionValue = [parsed objectForKey:@"Session"];
    if (sessionValue != nil && [sessionValue length] > 0) {
        [rtspSessionId release];
        rtspSessionId = [sessionValue copy];
    }

    NSString *transportValue = [parsed objectForKey:@"Transport"];
    if (transportValue != nil && [transportValue length] > 0) {
        [self parseTransportHeader:transportValue];
    }

    NSString *statusLine = [parsed objectForKey:@"statusLine"];
    if (statusLine != nil && [statusLine rangeOfString:@"200"].location != NSNotFound) {
        if ([method isEqualToString:@"SETUP"]) {
            isSetupComplete = YES;
            rtpSessionReady = YES;
        } else if ([method isEqualToString:@"PLAY"]) {
            isPlaying = YES;
            rtpSessionReady = YES;
        } else if ([method isEqualToString:@"PAUSE"]) {
            isPlaying = NO;
        }
    }
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing {
    (void)moreComing;
    if (browser != dacpServiceBrowser) {
        return;
    }
    BOOL matchesDACPIdentifier = dacpSearchName != nil &&
        [[service name] caseInsensitiveCompare:dacpSearchName] == NSOrderedSame;
    NSLog(@"RAOP: discovered DACP service %@ (matching sender=%d)",
          [service name], matchesDACPIdentifier);
    if (!matchesDACPIdentifier) {
        return;
    }

    [dacpService release];
    dacpService = [service retain];
    [dacpService setDelegate:self];
    [dacpService resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
             didNotSearch:(NSDictionary *)errorDict {
    if (browser == dacpServiceBrowser) {
        NSLog(@"RAOP: DACP Bonjour search failed: %@", errorDict);
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)service
               moreComing:(BOOL)moreComing {
    (void)moreComing;
    if (browser == dacpServiceBrowser && service == dacpService) {
        @synchronized(self) {
            [dacpAddress release];
            dacpAddress = nil;
            dacpPort = 0;
        }
        [dacpService setDelegate:nil];
        [dacpService release];
        dacpService = nil;
        [self notifyMetadataDidChange];
    }
}

- (void)netService:(NSNetService *)sender didResolveAddress:(NSData *)addressData {
    if (sender == nil) {
        return;
    }

    if (sender == dacpService) {
        NSString *resolvedAddress = [self addressStringFromData:addressData];
        if (resolvedAddress != nil && [sender port] > 0) {
            @synchronized(self) {
                [dacpAddress release];
                dacpAddress = [resolvedAddress copy];
                dacpPort = [sender port];
            }
            NSLog(@"RAOP: resolved sender DACP service at %@:%ld",
                  resolvedAddress, (long)[sender port]);
            [self notifyMetadataDidChange];
        }
        return;
    }

    deviceName = [[sender name] retain];
    NSString *serviceType = [sender type];
    if (serviceType != nil) {
        NSLog(@"Resolved AirPlay service: %@ (%@)", [sender name], serviceType);
    }

    NSString *resolvedAddress = [self addressStringFromData:addressData];
    if (resolvedAddress != nil) {
        [hostAddress release];
        hostAddress = [resolvedAddress copy];
    }

    if ([self openControlSocket]) {
        [self beginRTSPSession];
    }
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict {
    if (sender == dacpService) {
        NSLog(@"RAOP: DACP service %@ failed to resolve: %@", [sender name], errorDict);
    }
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
    NSLog(@"RAOP: Bonjour publication failed for %@: %@", [sender name], errorDict);
}

- (void)netServiceDidPublish:(NSNetService *)sender {
    NSLog(@"RAOP: Bonjour service published: %@", [sender name]);
}

- (void)play {
    [self sendDACPCommand:@"play"];
}

- (void)pause {
    [self sendDACPCommand:@"pause"];
}

- (void)nextTrack {
    [self sendDACPCommand:@"nextitem"];
}

- (void)previousTrack {
    [self sendDACPCommand:@"previtem"];
}

- (void)setVolume:(float)newVolume {
    if (newVolume < 0.0f) {
        newVolume = 0.0f;
    }
    if (newVolume > 1.0f) {
        newVolume = 1.0f;
    }
    @synchronized(self) {
        volume = newVolume;
    }
    [audioPlayer setVolume:newVolume];

    NSString *level = [NSString stringWithFormat:@"%.3f", PowerPlayDecibelsFromLinearGain(newVolume)];
    [self sendRTSPCommand:@"SET_PARAMETER" path:@"/" headers:[NSDictionary dictionaryWithObject:level forKey:@"volume"] body:nil];
}

- (NSString *)currentTitle {
    NSString *title = nil;
    @synchronized(self) {
        if (currentTitle == nil || [currentTitle length] == 0) {
            title = [trackName retain];
        } else {
            title = [currentTitle retain];
        }
    }
    return [title autorelease];
}

- (NSString *)connectedDeviceName {
    NSString *value = nil;
    @synchronized(self) {
        value = [connectedDeviceName retain];
    }
    return [value autorelease];
}

- (NSString *)artistName {
    NSString *value = nil;
    @synchronized(self) {
        value = [artistName retain];
    }
    return [value autorelease];
}

- (NSString *)albumName {
    NSString *value = nil;
    @synchronized(self) {
        value = [albumName retain];
    }
    return [value autorelease];
}

- (NSString *)trackName {
    NSString *value = nil;
    @synchronized(self) {
        value = [trackName retain];
    }
    return [value autorelease];
}

- (float)volumeValue {
    float value;
    @synchronized(self) {
        value = volume;
    }
    return value;
}

- (double)elapsedPlaybackTimeValue {
    double value;
    @synchronized(self) {
        value = elapsedPlaybackTime;
        if (isPlaying && progressReferenceTime > 0.0) {
            double currentTime = PowerPlayCurrentTime();
            if (lastAudioPacketTime > 0.0 && currentTime - lastAudioPacketTime > 1.5) {
                currentTime = lastAudioPacketTime + 1.5;
            }
            if (currentTime > progressReferenceTime) {
                value += currentTime - progressReferenceTime;
            }
            if (trackDuration > 0.0 && value > trackDuration) {
                value = trackDuration;
            }
        }
    }
    return value;
}

- (double)trackDurationValue {
    double value;
    @synchronized(self) {
        value = trackDuration;
    }
    return value;
}

- (NSData *)coverArtData {
    NSData *value = nil;
    @synchronized(self) {
        value = [coverArtData retain];
    }
    return [value autorelease];
}

- (BOOL)canControlSender {
    BOOL available;
    @synchronized(self) {
        available = incomingSessionActive &&
                    [dacpAddress length] > 0 &&
                    dacpPort > 0 &&
                    [dacpActiveRemote length] > 0;
    }
    return available;
}

- (BOOL)isPlaying {
    BOOL value;
    @synchronized(self) {
        value = isPlaying;
        if (value && lastAudioPacketTime > 0.0 &&
            PowerPlayCurrentTime() - lastAudioPacketTime > 1.5) {
            value = NO;
        }
    }
    return value;
}

@end
