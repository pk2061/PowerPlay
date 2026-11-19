#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import "RAOPReceiver.h"

@interface MemoryProbe : NSObject {
    NSConditionLock *signal;
}
- (id)initWithSignal:(NSConditionLock *)releaseSignal;
@end

@implementation MemoryProbe
- (id)initWithSignal:(NSConditionLock *)releaseSignal {
    self = [super init];
    if (self != nil) signal = [releaseSignal retain];
    return self;
}
- (void)dealloc {
    [signal lock];
    NSInteger count = [signal condition];
    [signal unlockWithCondition:count + 1];
    [signal release];
    [super dealloc];
}
@end

@interface MemoryTestReceiver : RAOPReceiver {
    NSConditionLock *released;
    NSConditionLock *finished;
    int testConnection;
}
- (void)startAudioWithSocket:(int)socketHandle;
- (void)startRTSPWithSocket:(int)socketHandle;
- (void)startStreamingRTSPWithSocket:(int)socketHandle;
- (void)markAudioActiveForTimeoutTest;
- (BOOL)waitForReleasedCount:(NSInteger)count;
- (BOOL)stopAndWait;
- (BOOL)hasFinished;
@end

@implementation MemoryTestReceiver
- (id)init {
    self = [super init];
    if (self != nil) {
        released = [[NSConditionLock alloc] initWithCondition:0];
        finished = [[NSConditionLock alloc] initWithCondition:0];
        testConnection = -1;
    }
    return self;
}
- (void)recordTemporaryObject {
    [[[MemoryProbe alloc] initWithSignal:released] autorelease];
}
- (BOOL)validateRTPPacket:(NSData *)packet {
    (void)packet;
    [self recordTemporaryObject];
    return NO;
}
- (void)updateDACPIdentityFromHeaders:(NSDictionary *)headers {
    (void)headers;
    [self recordTemporaryObject];
}
- (void)resetSessionAfterDisconnect {}
- (void)startAudioWithSocket:(int)socketHandle {
    acceptingRTSP = YES;
    isSetupComplete = YES;
    audioSocket = socketHandle;
    [NSThread detachNewThreadSelector:@selector(runAudio) toTarget:self withObject:nil];
}
- (void)startRTSPWithSocket:(int)socketHandle {
    acceptingRTSP = YES;
    testConnection = socketHandle;
    [NSThread detachNewThreadSelector:@selector(runRTSP) toTarget:self withObject:nil];
}
- (void)startStreamingRTSPWithSocket:(int)socketHandle {
    acceptingRTSP = YES;
    testConnection = socketHandle;
    [NSThread detachNewThreadSelector:@selector(runRTSP) toTarget:self withObject:nil];
}
- (void)markAudioActiveForTimeoutTest {
    @synchronized(self) {
        incomingSessionActive = YES;
        isPlaying = YES;
        isSetupComplete = YES;
        lastAudioPacketTime = [[NSDate date] timeIntervalSince1970];
    }
}
- (void)runAudio {
    [self receiveAudioPackets];
    [finished lock];
    [finished unlockWithCondition:1];
}
- (void)runRTSP {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [self handleRTSPConnection:testConnection];
    close(testConnection);
    [pool drain];
    [finished lock];
    [finished unlockWithCondition:1];
}
- (BOOL)waitForReleasedCount:(NSInteger)count {
    BOOL acquired = [released lockWhenCondition:count beforeDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
    if (acquired) [released unlock];
    return acquired;
}
- (BOOL)stopAndWait {
    acceptingRTSP = NO;
    BOOL acquired = [finished lockWhenCondition:1 beforeDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
    if (acquired) [finished unlock];
    return acquired;
}
- (BOOL)hasFinished {
    BOOL acquired = [finished lockWhenCondition:1 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if (acquired) [finished unlock];
    return acquired;
}
- (void)dealloc {
    [released release];
    [finished release];
    [super dealloc];
}
@end

static BOOL Check(BOOL condition, NSString *message) {
    if (!condition) NSLog(@"FAIL: %@", message);
    return condition;
}

static BOOL SendRTSPRequest(int socketHandle, NSString *request) {
    const char *bytes = [request UTF8String];
    if (send(socketHandle, bytes, strlen(bytes), 0) != (ssize_t)strlen(bytes)) return NO;
    char response[2048];
    size_t length = 0;
    response[0] = '\0';
    while (length < sizeof(response) - 1 && strstr(response, "\r\n\r\n") == NULL) {
        ssize_t received = recv(socketHandle, response + length, sizeof(response) - 1 - length, 0);
        if (received <= 0) return NO;
        length += (size_t)received;
        response[length] = '\0';
    }
    return strstr(response, "RTSP/1.0 200 OK") != NULL;
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    BOOL passed = YES;
    int audioSocket = socket(AF_INET, SOCK_DGRAM, 0);
    int senderSocket = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL audioReady = audioSocket >= 0 && senderSocket >= 0 &&
        bind(audioSocket, (struct sockaddr *)&address, sizeof(address)) == 0;
    passed &= Check(audioReady, @"audio test sockets must open");
    if (audioReady) {
        socklen_t addressLength = sizeof(address);
        getsockname(audioSocket, (struct sockaddr *)&address, &addressLength);
        MemoryTestReceiver *receiver = [[MemoryTestReceiver alloc] init];
        [receiver startAudioWithSocket:audioSocket];
        unsigned char packet[12] = { 0x80, 0x60 };
        NSInteger packetIndex;
        for (packetIndex = 1; packetIndex <= 3; packetIndex++) {
            passed &= Check(sendto(senderSocket, packet, sizeof(packet), 0,
                                   (struct sockaddr *)&address, addressLength) == sizeof(packet),
                            @"audio test packet must be sent");
            passed &= Check([receiver waitForReleasedCount:packetIndex],
                            @"audio packet temporaries must be released while the thread is running");
        }
        passed &= Check([receiver stopAndWait], @"audio receiver thread must stop");
        [receiver release];
    } else if (audioSocket >= 0) {
        close(audioSocket);
    }
    if (senderSocket >= 0) close(senderSocket);

    int sockets[2];
    BOOL rtspReady = socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0;
    passed &= Check(rtspReady, @"RTSP test sockets must open");
    if (rtspReady) {
        struct timeval timeout;
        timeout.tv_sec = 3;
        timeout.tv_usec = 0;
        setsockopt(sockets[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        MemoryTestReceiver *receiver = [[MemoryTestReceiver alloc] init];
        [receiver startRTSPWithSocket:sockets[1]];
        NSInteger requestIndex;
        for (requestIndex = 1; requestIndex <= 3; requestIndex++) {
            NSString *request = [NSString stringWithFormat:@"OPTIONS * RTSP/1.0\r\nCSeq: %ld\r\n\r\n", (long)requestIndex];
            passed &= Check(SendRTSPRequest(sockets[0], request), @"RTSP request must receive a response");
            passed &= Check([receiver waitForReleasedCount:requestIndex],
                            @"RTSP temporaries must be released before the connection closes");
        }
        NSString *artworkRequest = @"SET_PARAMETER * RTSP/1.0\r\nCSeq: 4\r\nContent-Type: image/jpeg\r\nContent-Length: 5\r\n\r\nABCDE";
        passed &= Check(SendRTSPRequest(sockets[0], artworkRequest), @"artwork request must receive a response");
        passed &= Check([receiver waitForReleasedCount:4], @"artwork request temporaries must be released");
        passed &= Check([[receiver coverArtData] isEqualToData:[@"ABCDE" dataUsingEncoding:NSASCIIStringEncoding]],
                        @"current artwork must remain available after the request pool drains");
        passed &= Check(SendRTSPRequest(sockets[0], @"OPTIONS * RTSP/1.0\r\nCSeq: 5\r\n\r\n"),
                        @"RTSP connection must remain usable after artwork");
        passed &= Check([receiver waitForReleasedCount:5], @"subsequent request temporaries must be released");
        close(sockets[0]);
        passed &= Check([receiver stopAndWait], @"RTSP receiver thread must stop");
        [receiver release];
    }

    int streamingSockets[2];
    BOOL streamingReady = socketpair(AF_UNIX, SOCK_STREAM, 0, streamingSockets) == 0;
    passed &= Check(streamingReady, @"streaming RTSP test sockets must open");
    if (streamingReady) {
        struct timeval shortTimeout;
        shortTimeout.tv_sec = 0;
        shortTimeout.tv_usec = 100000;
        setsockopt(streamingSockets[1], SOL_SOCKET, SO_RCVTIMEO, &shortTimeout, sizeof(shortTimeout));
        struct timeval clientTimeout;
        clientTimeout.tv_sec = 2;
        clientTimeout.tv_usec = 0;
        setsockopt(streamingSockets[0], SOL_SOCKET, SO_RCVTIMEO, &clientTimeout, sizeof(clientTimeout));
        MemoryTestReceiver *receiver = [[MemoryTestReceiver alloc] init];
        [receiver startStreamingRTSPWithSocket:streamingSockets[1]];
        passed &= Check(SendRTSPRequest(streamingSockets[0], @"OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n"),
                        @"active RTSP session should answer its first request");
        [receiver markAudioActiveForTimeoutTest];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        passed &= Check(![receiver hasFinished], @"active RTP should keep the RTSP session alive after a socket timeout");
        passed &= Check(SendRTSPRequest(streamingSockets[0], @"OPTIONS * RTSP/1.0\r\nCSeq: 2\r\n\r\n"),
                        @"active RTSP session should answer requests after a read timeout");
        close(streamingSockets[0]);
        passed &= Check([receiver stopAndWait], @"streaming RTSP receiver should stop after peer close");
        [receiver release];
    }
    NSLog(@"Receiver memory tests %@", passed ? @"passed" : @"failed");
    [pool drain];
    return passed ? 0 : 1;
}