#import "RAOPReceiver.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

@implementation RAOPReceiver

- (id)init {
    self = [super init];
    if (self != nil) {
        discoveredServices = [[NSMutableArray alloc] init];
        currentTitle = [[NSString alloc] initWithString:@"Waiting for AirPlay source..."]; 
        coverArtData = nil;
        isPlaying = NO;
        volume = 0.5f;
        controlPort = 5000;
        audioPort = 6000;
        timingPort = 6001;
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

        audioPlayer = [[CoreAudioPlayer alloc] initWithFormat:format];
        serviceBrowser = [[NSNetServiceBrowser alloc] init];
        [serviceBrowser setDelegate:self];
    }
    return self;
}

- (void)dealloc {
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
    [serviceBrowser stop];
    [serviceBrowser release];
    [discoveredServices release];
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

- (void)startBrowsing {
    [serviceBrowser searchForServicesOfType:@"_raop._tcp." inDomain:@""];
}

- (void)stopBrowsing {
    [serviceBrowser stop];
    if (controlSocket >= 0) {
        close(controlSocket);
        controlSocket = -1;
    }
    [self teardownSession];
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
        [metadata setObject:[NSNumber numberWithInteger:audioPort] forKey:@"audio_port"];
    }

    if ([self openUDPListenerOnPort:timingPort socket:&timingSocket]) {
        [metadata setObject:[NSNumber numberWithInteger:timingPort] forKey:@"timing_port"];
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
    for (NSUInteger i = 0; i < [parts count]; i++) {
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
                NSInteger portValue = [firstPortString integerValue];
                if (portValue > 0) {
                    audioPort = portValue;
                    foundAnyPort = YES;
                }
            }
        } else if ([key isEqualToString:@"control_port"]) {
            NSInteger portValue = [value integerValue];
            if (portValue > 0) {
                controlPort = portValue;
                foundAnyPort = YES;
            }
        } else if ([key isEqualToString:@"timing_port"]) {
            NSInteger portValue = [value integerValue];
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
            NSInteger serverPort = [firstPort integerValue];
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
            NSInteger controlPortValue = [tail integerValue];
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

    NSArray *lines = [traceString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSUInteger i = 0; i < [lines count]; i++) {
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
        for (NSUInteger i = 12; i < [packet length]; i++) {
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

#pragma mark - NSNetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    if (service == nil) {
        return;
    }

    [service setDelegate:self];
    [discoveredServices addObject:service];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [discoveredServices removeObject:service];
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
