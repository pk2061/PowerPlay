#import <Cocoa/Cocoa.h>
#import <math.h>
#import "AirPlayReceiverAppDelegate.h"

@interface TestPlaybackReceiver : RAOPReceiver {
    NSString *lastCommand;
    NSUInteger commandCount;
}
- (void)setTestPlaying:(BOOL)playing packetTime:(double)packetTime referenceTime:(double)referenceTime elapsed:(double)elapsed;
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
- (void)sendDACPCommand:(NSString *)command {
    [lastCommand release];
    lastCommand = [command copy];
    commandCount++;
}
- (NSString *)lastCommand { return lastCommand; }
- (NSUInteger)commandCount { return commandCount; }
- (void)dealloc {
    [lastCommand release];
    [super dealloc];
}
@end

static BOOL Check(BOOL condition, NSString *message) {
    if (!condition) NSLog(@"FAIL: %@", message);
    return condition;
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

    [delegate applicationWillTerminate:[NSNotification notificationWithName:@"TestTermination" object:nil]];
    [delegate release];
    NSLog(@"Playback state tests %@", passed ? @"passed" : @"failed");
    [pool drain];
    return passed ? 0 : 1;
}