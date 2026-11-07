#import "RAOPReceiver.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <stdio.h>

typedef struct bio_st PowerPlayBIO;
typedef struct rsa_st PowerPlayRSA;

extern PowerPlayBIO *BIO_new_file(const char *filename, const char *mode);
extern PowerPlayRSA *PEM_read_bio_RSAPrivateKey(PowerPlayBIO *bio, PowerPlayRSA **rsa, void *callback, void *userData);
extern int BIO_free(PowerPlayBIO *bio);
extern int RSA_size(const PowerPlayRSA *rsa);
extern int RSA_private_encrypt(int inputLength, const unsigned char *input, unsigned char *output, PowerPlayRSA *rsa, int padding);
extern void RSA_free(PowerPlayRSA *rsa);

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

    NSString *keyPath = [[NSBundle mainBundle] pathForResource:@"RAOPPrivateKey" ofType:@"pem"];
    PowerPlayBIO *keyFile = keyPath == nil ? NULL : BIO_new_file([keyPath fileSystemRepresentation], "r");
    PowerPlayRSA *privateKey = keyFile == NULL ? NULL : PEM_read_bio_RSAPrivateKey(keyFile, NULL, NULL, NULL);
    if (keyFile != NULL) {
        BIO_free(keyFile);
    }
    if (privateKey == NULL) {
        return nil;
    }

    int signatureCapacity = RSA_size(privateKey);
    unsigned char *signature = (unsigned char *)malloc((size_t)signatureCapacity);
    int signatureLength = signature == NULL ? -1 : RSA_private_encrypt(
        (int)signedLength, signedData, signature, privateKey, 1);
    RSA_free(privateKey);
    if (signatureLength <= 0) {
        free(signature);
        return nil;
    }

    NSString *response = PowerPlayEncodeBase64WithoutPadding(signature, (NSUInteger)signatureLength);
    free(signature);
    return response;
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
                        if (lengthValue < 0 || lengthValue > 65536) {
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
            } else if ([buffer length] > 65536) {
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
            return nil;
        }
        [buffer appendBytes:chunk length:(NSUInteger)received];
        if ([buffer length] > 131072) {
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

- (id)init {
    self = [super init];
    if (self != nil) {
        publishedService = nil;
        deviceIdentifier = nil;
        listenerSocket = -1;
        rtpControlSocket = -1;
        acceptingRTSP = NO;
        currentTitle = [[NSString alloc] initWithString:@"Waiting for AirPlay source..."]; 
        coverArtData = nil;
        isPlaying = NO;
        volume = 0.5f;
        controlPort = 5000;
        audioPort = 6000;
        timingPort = 6002;
        rtpControlPort = 6001;
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
    [currentTitle release];
    [coverArtData release];
    [resolvedService release];
    [rtspSessionId release];
    [hostAddress release];
    [artistName release];
    [albumName release];
    [trackName release];
    [metadata release];
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

- (void)handleRTSPConnection:(int)incomingSocket {
    struct sockaddr_in peerAddress;
    socklen_t peerLength = sizeof(peerAddress);
    memset(&peerAddress, 0, sizeof(peerAddress));
    if (getpeername(incomingSocket, (struct sockaddr *)&peerAddress, &peerLength) == 0) {
        [hostAddress release];
        hostAddress = [[NSString stringWithUTF8String:inet_ntoa(peerAddress.sin_addr)] copy];
    }

    [rtspSessionId release];
    rtspSessionId = [[NSString stringWithFormat:@"PowerPlay-%u-%u",
        (unsigned int)getpid(), (unsigned int)time(NULL)] copy];
    rtspSessionEstablished = NO;
    isSetupComplete = NO;
    rtpSessionReady = NO;
    isPlaying = NO;

    while (acceptingRTSP) {
        NSDictionary *request = PowerPlayReadRTSPRequest(incomingSocket);
        if (request == nil) {
            break;
        }

        NSString *requestLine = [request objectForKey:@"requestLine"];
        NSArray *requestParts = [requestLine componentsSeparatedByString:@" "];
        if ([requestParts count] < 2) {
            break;
        }
        NSString *method = [[requestParts objectAtIndex:0] uppercaseString];
        NSDictionary *headers = [request objectForKey:@"headers"];
        NSData *requestBodyData = [request objectForKey:@"body"];
        NSString *requestBodyText = requestBodyData == nil ? @"" : [[[NSString alloc] initWithData:requestBodyData encoding:NSUTF8StringEncoding] autorelease];
        NSString *requestParameter = requestBodyText == nil ? @"" : [requestBodyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *cseq = [headers objectForKey:@"cseq"];
        if (cseq == nil) {
            cseq = @"1";
        }
        NSString *sessionHeader = [headers objectForKey:@"session"];
        NSString *transport = [headers objectForKey:@"transport"];
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
            rtspSessionEstablished = YES;
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
        } else if ([method isEqualToString:@"SETUP"]) {
            if (!rtspSessionEstablished) {
                status = @"455 Method Not Valid in This State";
            } else if (transport == nil || [transport rangeOfString:@"RTP/AVP/UDP" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                status = @"461 Unsupported Transport";
            } else {
                NSInteger senderControlPort = PowerPlayTransportPort(transport, @"control_port");
                NSInteger senderTimingPort = PowerPlayTransportPort(transport, @"timing_port");
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
                    [metadata setObject:[NSNumber numberWithInt:(int)senderTimingPort] forKey:@"sender_timing_port"];
                    responseHeaders = [NSString stringWithFormat:
                        @"Session: %@;timeout=60\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port=%ld;control_port=%ld;timing_port=%ld\r\n",
                        rtspSessionId, (long)audioPort, (long)rtpControlPort, (long)timingPort];
                }
            }
        } else if ([method isEqualToString:@"RECORD"]) {
            if (!isSetupComplete || (sessionHeader != nil && ![sessionHeader hasPrefix:rtspSessionId])) {
                status = @"455 Method Not Valid in This State";
            } else {
                isPlaying = YES;
                [audioPlayer start];
                responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            }
        } else if ([method isEqualToString:@"PAUSE"]) {
            isPlaying = NO;
            [audioPlayer stop];
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
        } else if ([method isEqualToString:@"TEARDOWN"]) {
            isPlaying = NO;
            isSetupComplete = NO;
            rtpSessionReady = NO;
            rtspSessionEstablished = NO;
            [audioPlayer stop];
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
        } else if ([method isEqualToString:@"FLUSH"] ||
                   [method isEqualToString:@"SET_PARAMETER"]) {
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            contentType = @"text/parameters";
            if ([requestParameter length] > 0) {
                if ([requestParameter rangeOfString:@"volume" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    NSScanner *scanner = [NSScanner scannerWithString:requestParameter];
                    NSString *volumeLabel = nil;
                    float parsedVolume = 0.0f;
                    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
                    if ([scanner scanUpToCharactersFromSet:whitespace intoString:&volumeLabel] &&
                        [scanner scanFloat:&parsedVolume] &&
                        parsedVolume >= 0.0f && parsedVolume <= 1.0f) {
                        volume = parsedVolume;
                    }
                    responseBody = [NSString stringWithFormat:@"volume: %.3f\r\n", volume];
                } else {
                    responseBody = [NSString stringWithFormat:@"%@\r\n", requestParameter];
                }
            } else {
                responseBody = @"";
            }
        } else if ([method isEqualToString:@"GET_PARAMETER"]) {
            responseHeaders = [NSString stringWithFormat:@"Session: %@;timeout=60\r\n", rtspSessionId];
            contentType = @"text/parameters";
            if ([requestParameter length] > 0) {
                if ([requestParameter rangeOfString:@"volume" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    responseBody = [NSString stringWithFormat:@"volume: %.3f\r\n", volume];
                } else if ([requestParameter rangeOfString:@"position" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    responseBody = @"position: 0.000000\r\n";
                } else {
                    responseBody = [NSString stringWithFormat:@"%@: %@\r\n", requestParameter, @""];
                }
            } else {
                responseBody = [NSString stringWithFormat:@"volume: %.3f\r\n", volume];
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
    return (controlSocket >= 0) && (hostAddress != nil) && ([hostAddress length] > 0);
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
        [self parseMetadataFromPlistData:packet];
        if ([parsedMetadata objectForKey:@"title"] != nil) {
            NSString *newTitle = [parsedMetadata objectForKey:@"title"];
            [trackName release];
            trackName = [newTitle copy];
            [currentTitle release];
            currentTitle = [newTitle copy];
            [self notifyTrackChangeIfNeeded];
        }
        if ([parsedMetadata objectForKey:@"coverArtData"] != nil) {
            NSData *coverData = [parsedMetadata objectForKey:@"coverArtData"];
            [coverArtData release];
            coverArtData = [coverData copy];
        }
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
    if (parsed == nil || [parsed count] == 0) {
        return;
    }

    NSString *newTitle = [parsed objectForKey:@"title"];
    if (newTitle != nil && [newTitle length] > 0) {
        [trackName release];
        trackName = [newTitle copy];
        [currentTitle release];
        currentTitle = [newTitle copy];
        [self notifyTrackChangeIfNeeded];
    }

    NSString *newArtist = [parsed objectForKey:@"artist"];
    if (newArtist != nil && [newArtist length] > 0) {
        [artistName release];
        artistName = [newArtist copy];
    }

    NSString *newAlbum = [parsed objectForKey:@"album"];
    if (newAlbum != nil && [newAlbum length] > 0) {
        [albumName release];
        albumName = [newAlbum copy];
    }

    NSData *newCoverData = [parsed objectForKey:@"coverArtData"];
    if (newCoverData != nil && [newCoverData length] > 0) {
        [coverArtData release];
        coverArtData = [newCoverData copy];
    }

    [metadata addEntriesFromDictionary:parsed];
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

    uint32_t ssrc = ((uint32_t)bytes[8] << 24) |
                    ((uint32_t)bytes[9] << 16) |
                    ((uint32_t)bytes[10] << 8) |
                    (uint32_t)bytes[11];
    if (ssrc == 0) {
        return NO;
    }

    unsigned int sequenceNumber = ((unsigned int)bytes[2] << 8) | bytes[3];
    unsigned int timestamp = ((unsigned int)bytes[4] << 24) |
                            ((unsigned int)bytes[5] << 16) |
                            ((unsigned int)bytes[6] << 8) |
                            ((unsigned int)bytes[7]);

    if (sequenceNumber == 0 && timestamp == 0) {
        BOOL hasNonZeroPayload = NO;
        NSUInteger i;
        for (i = 12; i < [packet length]; i++) {
            if (((const unsigned char *)[packet bytes])[i] != 0) {
                hasNonZeroPayload = YES;
                break;
            }
        }
        if (!hasNonZeroPayload) {
            return NO;
        }
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

- (void)netService:(NSNetService *)sender didResolveAddress:(NSData *)addressData {
    if (sender == nil) {
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

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
    NSLog(@"RAOP: Bonjour publication failed for %@: %@", [sender name], errorDict);
}

- (void)netServiceDidPublish:(NSNetService *)sender {
    NSLog(@"RAOP: Bonjour service published: %@", [sender name]);
}

- (void)play {
    if (controlSocket < 0) {
        return;
    }

    if (!rtspSessionEstablished) {
        [self beginRTSPSession];
    }

    if (!isSetupComplete) {
        NSMutableDictionary *setupHeaders = [NSMutableDictionary dictionary];
        NSString *transportHeader = [NSString stringWithFormat:@"RTP/AVP/UDP;unicast;mode=play;control_port=%ld;timing_port=%ld;", (long)audioPort, (long)timingPort];
        [setupHeaders setObject:transportHeader forKey:@"Transport"];
        [self sendRTSPCommand:@"SETUP" path:@"/stream=0" headers:setupHeaders body:nil];
    }

    NSMutableDictionary *playHeaders = [NSMutableDictionary dictionary];
    [playHeaders setObject:@"0.0-" forKey:@"Range"];
    [self sendRTSPCommand:@"PLAY" path:@"/" headers:playHeaders body:nil];

    isPlaying = YES;
    rtpSessionReady = YES;
    [currentTitle release];
    currentTitle = [[NSString alloc] initWithString:@"Playing via AirPlay"];
    if (audioPlayer != nil) {
        [audioPlayer start];
    }
}

- (void)pause {
    if (controlSocket < 0) {
        return;
    }

    if ([self isSessionReady]) {
        [self sendRTSPCommand:@"PAUSE" path:@"/" headers:nil body:nil];
    }
    isPlaying = NO;
    if (audioPlayer != nil) {
        [audioPlayer stop];
    }
}

- (void)nextTrack {
    if (controlSocket < 0) {
        return;
    }

    [self sendRTSPCommand:@"GET_PARAMETER" path:@"/" headers:[NSDictionary dictionaryWithObject:@"next" forKey:@"Scale"] body:nil];
}

- (void)previousTrack {
    if (controlSocket < 0) {
        return;
    }

    [self sendRTSPCommand:@"GET_PARAMETER" path:@"/" headers:[NSDictionary dictionaryWithObject:@"previous" forKey:@"Scale"] body:nil];
}

- (void)setVolume:(float)newVolume {
    volume = newVolume;
    if (volume < 0.0f) {
        volume = 0.0f;
    }
    if (volume > 1.0f) {
        volume = 1.0f;
    }

    NSString *level = [NSString stringWithFormat:@"%.3f", volume];
    [self sendRTSPCommand:@"SET_PARAMETER" path:@"/" headers:[NSDictionary dictionaryWithObject:level forKey:@"volume"] body:nil];
}

- (NSString *)currentTitle {
    if (currentTitle == nil || [currentTitle length] == 0) {
        return trackName;
    }
    return currentTitle;
}

- (NSString *)artistName {
    return artistName;
}

- (NSString *)albumName {
    return albumName;
}

- (NSString *)trackName {
    return trackName;
}

- (float)volumeValue {
    return volume;
}

- (NSData *)coverArtData {
    return coverArtData;
}

- (BOOL)isPlaying {
    return isPlaying;
}

@end
