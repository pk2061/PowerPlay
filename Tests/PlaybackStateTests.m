#import <Cocoa/Cocoa.h>
#import <math.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import "AirPlayReceiverAppDelegate.h"

@interface TestPlaybackReceiver : RAOPReceiver {
    NSString *lastCommand;
    NSUInteger commandCount;
}
- (void)setTestPlaying:(BOOL)playing packetTime:(double)packetTime referenceTime:(double)referenceTime elapsed:(double)elapsed;
- (void)setTestConnected:(BOOL)connected;
- (NSString *)lastCommand;
- (NSUInteger)commandCount;
@end

@implementation TestPlaybackReceiver
- (void)setTestPlaying:(BOOL)playing packetTime:(double)packetTime referenceTime:(double)referenceTime elapsed:(double)elapsed {
    @synchronized(self) {
        incomingSessionActive = YES;
        isPlaying = playing;
        lastAudioPacketTime = packetTime;
        progressReferenceTime = referenceTime;
        elapsedPlaybackTime = elapsed;
    }
}
- (void)setTestConnected:(BOOL)connected { incomingSessionActive = connected; }
- (void)sendDACPCommand:(NSString *)command {
    [lastCommand release];
    lastCommand = [command copy];
    commandCount++;
}
- (NSString *)lastCommand { return lastCommand; }
- (NSUInteger)commandCount { return commandCount; }
- (BOOL)canControlSender { return incomingSessionActive; }
- (void)dealloc {
    [lastCommand release];
    [super dealloc];
}
@end

@interface DACPTestReceiver : RAOPReceiver
- (void)configureAddress:(NSData *)address;
- (void)simulateAudioPacket;
@end

@implementation DACPTestReceiver
- (void)configureAddress:(NSData *)address {
    const struct sockaddr_in *socketAddress = (const struct sockaddr_in *)[address bytes];
    @synchronized(self) {
        incomingSessionActive = YES;
        isPlaying = YES;
        lastAudioPacketTime = [[NSDate date] timeIntervalSince1970];
        progressReferenceTime = lastAudioPacketTime - 5.0;
        elapsedPlaybackTime = 10.0;
        dacpAddress = [@"127.0.0.1" copy];
        dacpAddressData = [address copy];
        dacpPort = ntohs(socketAddress->sin_port);
        dacpActiveRemote = [@"test-token" copy];
    }
}
- (void)simulateAudioPacket {
    @synchronized(self) {
        lastAudioPacketTime = [[NSDate date] timeIntervalSince1970];
    }
}
@end

@interface DACPTestServer : NSObject {
    int listener;
    NSData *address;
    NSConditionLock *responseGate;
    NSString *response;
}
- (NSData *)address;
- (void)startWithResponse:(NSString *)status;
- (void)allowResponse;
@end

@implementation DACPTestServer
- (id)init {
    self = [super init];
    if (self != nil) {
        listener = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in socketAddress;
        memset(&socketAddress, 0, sizeof(socketAddress));
        socketAddress.sin_len = sizeof(socketAddress);
        socketAddress.sin_family = AF_INET;
        socketAddress.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (listener < 0 || bind(listener, (struct sockaddr *)&socketAddress, sizeof(socketAddress)) != 0 ||
            listen(listener, 4) != 0) {
            if (listener >= 0) close(listener);
            [self release];
            return nil;
        }
        socklen_t addressLength = sizeof(socketAddress);
        getsockname(listener, (struct sockaddr *)&socketAddress, &addressLength);
        address = [[NSData alloc] initWithBytes:&socketAddress length:addressLength];
        responseGate = [[NSConditionLock alloc] initWithCondition:0];
    }
    return self;
}
- (NSData *)address { return address; }
- (void)startWithResponse:(NSString *)status {
    [response release];
    response = [status copy];
    [responseGate lock];
    [responseGate unlockWithCondition:0];
    [NSThread detachNewThreadSelector:@selector(serve) toTarget:self withObject:nil];
}
- (void)allowResponse {
    [responseGate lock];
    [responseGate unlockWithCondition:1];
}
- (void)serve {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int client = accept(listener, NULL, NULL);
    if (client >= 0) {
        char buffer[2048];
        recv(client, buffer, sizeof(buffer), 0);
        [responseGate lockWhenCondition:1];
        [responseGate unlock];
        const char *status = [response UTF8String];
        send(client, "HTTP/1.1 ", 9, 0);
        send(client, status, strlen(status), 0);
        send(client, "\r\nContent-Length: 0\r\n\r\n", 23, 0);
        close(client);
    }
    [pool drain];
}
- (void)dealloc {
    if (listener >= 0) close(listener);
    [address release];
    [responseGate release];
    [response release];
    [super dealloc];
}
@end

static BOOL Check(BOOL condition, NSString *message) {
    if (!condition) NSLog(@"FAIL: %@", message);
    return condition;
}

static BOOL WaitForDACPCommand(RAOPReceiver *receiver) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4.0];
    while ([receiver isDACPPlaybackCommandPending] && [deadline timeIntervalSinceNow] > 0.0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return ![receiver isDACPPlaybackCommandPending];
}

static BOOL SendTransportKey(NSWindow *window, unichar character, NSUInteger modifiers, unsigned short keyCode) {
    NSString *characters = [NSString stringWithCharacters:&character length:1];
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:modifiers
                                    timestamp:0 windowNumber:[window windowNumber] context:nil
                                   characters:characters charactersIgnoringModifiers:characters
                                    isARepeat:NO keyCode:keyCode];
    return [window performKeyEquivalent:event];
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    TestPlaybackReceiver *receiver = [[TestPlaybackReceiver alloc] init];
    AirPlayReceiverAppDelegate *delegate = [[AirPlayReceiverAppDelegate alloc] init];
    [delegate setValue:receiver forKey:@"receiver"];
    [delegate buildUI];
    NSButton *button = [delegate valueForKey:@"playPauseButton"];
    NSTextField *status = [delegate valueForKey:@"statusText"];
    BOOL passed = YES;
    double now = [[NSDate date] timeIntervalSince1970];

    [receiver setTestPlaying:YES packetTime:0.0 referenceTime:now - 10.0 elapsed:23.0];
    [delegate refreshPlaybackProgress:nil];
    passed &= Check(![receiver isPlaying] && fabs([receiver elapsedPlaybackTimeValue] - 23.0) < 0.01,
                    @"RECORD without audio must not start playback or advance the clock");
    passed &= Check([[button toolTip] isEqualToString:@"Play"], @"idle button should offer Play");
    passed &= Check([[status stringValue] hasPrefix:@"Connected"], @"idle status should show a connection without playback");

    [receiver setTestPlaying:YES packetTime:now referenceTime:now - 1.0 elapsed:23.0];
    [delegate refreshPlaybackProgress:nil];
    passed &= Check([receiver isPlaying] && [receiver elapsedPlaybackTimeValue] >= 24.0,
                    @"recent audio must indicate playing and advance the clock");
    passed &= Check([[button toolTip] isEqualToString:@"Pause"], @"playing button should offer Pause");
    passed &= Check([[status stringValue] hasPrefix:@"Playing"], @"playing status should reflect playback");
    [delegate togglePlayPause:nil];
    passed &= Check([receiver commandCount] == 1 && [[receiver lastCommand] isEqualToString:@"playpause"],
                    @"pause action should toggle the sender");

    [receiver setTestPlaying:YES packetTime:now - 5.0 referenceTime:now - 10.0 elapsed:23.0];
    [delegate refreshPlaybackProgress:nil];
    double pausedElapsed = [receiver elapsedPlaybackTimeValue];
    passed &= Check(![receiver isPlaying] && fabs(pausedElapsed - 29.5) < 0.01,
                    @"audio inactivity must stop playback and freeze the clock");
    passed &= Check([[button toolTip] isEqualToString:@"Play"], @"paused button should offer Play");
    passed &= Check([[status stringValue] hasPrefix:@"Connected"], @"paused status should not claim playback");
    [delegate togglePlayPause:nil];
    passed &= Check([receiver commandCount] == 2 && [[receiver lastCommand] isEqualToString:@"playpause"],
                    @"play action should toggle the sender again");

    [receiver setTestPlaying:YES packetTime:[[NSDate date] timeIntervalSince1970]
               referenceTime:[[NSDate date] timeIntervalSince1970] elapsed:pausedElapsed];
    [delegate refreshPlaybackProgress:nil];
    passed &= Check([receiver isPlaying] && [[button toolTip] isEqualToString:@"Pause"],
                    @"resumed audio must restore the pause button");

    [delegate refreshUI];
    NSWindow *window = [delegate valueForKey:@"window"];
    passed &= Check(SendTransportKey(window, NSLeftArrowFunctionKey, NSNumericPadKeyMask | NSFunctionKeyMask, 123) &&
                    [receiver commandCount] == 3 && [[receiver lastCommand] isEqualToString:@"previtem"],
                    @"left arrow should send previous track");
    passed &= Check(SendTransportKey(window, ' ', 0, 49) &&
                    [receiver commandCount] == 4 && [[receiver lastCommand] isEqualToString:@"playpause"],
                    @"space should toggle playback");
    passed &= Check(SendTransportKey(window, NSRightArrowFunctionKey, NSNumericPadKeyMask | NSFunctionKeyMask, 124) &&
                    [receiver commandCount] == 5 && [[receiver lastCommand] isEqualToString:@"nextitem"],
                    @"right arrow should send next track");
    SendTransportKey(window, ' ', NSCommandKeyMask, 49);
    passed &= Check([receiver commandCount] == 5, @"modified keys must not trigger transport shortcuts");
    [receiver setTestConnected:NO];
    [delegate refreshUI];
    SendTransportKey(window, NSLeftArrowFunctionKey, NSNumericPadKeyMask | NSFunctionKeyMask, 123);
    SendTransportKey(window, ' ', 0, 49);
    SendTransportKey(window, NSRightArrowFunctionKey, NSNumericPadKeyMask | NSFunctionKeyMask, 124);
    passed &= Check([receiver commandCount] == 5, @"disconnected transport buttons must ignore shortcuts");

    [delegate applicationWillTerminate:[NSNotification notificationWithName:@"TestTermination" object:nil]];
    [delegate release];

    DACPTestServer *server = [[DACPTestServer alloc] init];
    DACPTestReceiver *dacpReceiver = [[DACPTestReceiver alloc] init];
    passed &= Check(server != nil, @"local DACP test server must start");
    if (server != nil) {
        [dacpReceiver configureAddress:[server address]];
        AirPlayReceiverAppDelegate *dacpDelegate = [[AirPlayReceiverAppDelegate alloc] init];
        [dacpDelegate setValue:dacpReceiver forKey:@"receiver"];
        [dacpReceiver release];
        [dacpDelegate buildUI];
        NSButton *dacpButton = [dacpDelegate valueForKey:@"playPauseButton"];
        [server startWithResponse:@"204 No Content"];
        [dacpDelegate togglePlayPause:nil];
        passed &= Check([dacpReceiver isDACPPlaybackCommandPending], @"toggle should remain pending until its response");
        passed &= Check(![dacpButton isEnabled], @"button must be disabled while the toggle is pending");
        passed &= Check(!SendTransportKey([dacpDelegate valueForKey:@"window"], ' ', 0, 49),
                @"space must not trigger while the toggle is pending");
        [dacpReceiver togglePlayPause];
        [server allowResponse];
        passed &= Check(WaitForDACPCommand(dacpReceiver), @"pause command should complete");
        double frozenElapsed = [dacpReceiver elapsedPlaybackTimeValue];
        [dacpReceiver simulateAudioPacket];
        [dacpDelegate refreshUI];
        passed &= Check(![dacpReceiver isPlaying] && fabs([dacpReceiver elapsedPlaybackTimeValue] - frozenElapsed) < 0.01,
                        @"acknowledged pause must ignore continuing audio packets");
        passed &= Check([dacpButton isEnabled] && [[dacpButton toolTip] isEqualToString:@"Play"],
                        @"acknowledged pause must restore the play button");

        [server startWithResponse:@"500 Internal Server Error"];
        [dacpDelegate togglePlayPause:nil];
        [server allowResponse];
        passed &= Check(WaitForDACPCommand(dacpReceiver) && ![dacpReceiver isPlaying],
                        @"failed toggle must leave playback paused");
        [dacpDelegate refreshUI];
        passed &= Check([dacpButton isEnabled] && [[dacpButton toolTip] isEqualToString:@"Play"],
                        @"failed toggle must restore the play button");

        [server startWithResponse:@"204 No Content"];
        [dacpDelegate togglePlayPause:nil];
        [server allowResponse];
        passed &= Check(WaitForDACPCommand(dacpReceiver) && [dacpReceiver isPlaying],
                        @"acknowledged second toggle must resume playback");
        [dacpDelegate refreshUI];
        passed &= Check([dacpButton isEnabled] && [[dacpButton toolTip] isEqualToString:@"Pause"],
                        @"acknowledged resume must restore the pause button");
        [dacpDelegate applicationWillTerminate:[NSNotification notificationWithName:@"TestTermination" object:nil]];
        [dacpDelegate release];
    } else {
        [dacpReceiver release];
    }
    [server release];
    NSLog(@"Playback state tests %@", passed ? @"passed" : @"failed");
    [pool drain];
    return passed ? 0 : 1;
}