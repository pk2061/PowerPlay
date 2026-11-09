#import <Cocoa/Cocoa.h>
#import "AirPlayReceiverAppDelegate.h"

NSString * const PowerPlayMetadataDidChangeNotification = @"PowerPlayMetadataDidChangeNotification";
NSString * const PowerPlayVolumeDidChangeNotification = @"PowerPlayVolumeDidChangeNotification";
NSString * const PowerPlayPlaybackProgressDidChangeNotification = @"PowerPlayPlaybackProgressDidChangeNotification";

static NSUInteger notificationCount = 0;
static NSString *notifiedTitle = nil;
static NSString *notifiedArtist = nil;
static NSString *notifiedAlbum = nil;
static BOOL notifiedArtwork = NO;

@implementation GrowlNotifier
- (void)notifyTrackTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album image:(NSImage *)image {
    notificationCount++;
    [notifiedTitle release];
    notifiedTitle = [title copy];
    [notifiedArtist release];
    notifiedArtist = [artist copy];
    [notifiedAlbum release];
    notifiedAlbum = [album copy];
    notifiedArtwork = image != nil;
}
@end

@interface RAOPReceiver (GrowlTest)
- (void)setTestTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSData *)artwork;
@end

@implementation RAOPReceiver
- (void)setTestTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSData *)artwork {
    [trackName release];
    trackName = [title copy];
    [artistName release];
    artistName = [artist copy];
    [albumName release];
    albumName = [album copy];
    [coverArtData release];
    coverArtData = [artwork copy];
}
- (NSString *)currentTitle { return trackName; }
- (NSString *)trackName { return trackName; }
- (NSString *)artistName { return artistName; }
- (NSString *)albumName { return albumName; }
- (NSData *)coverArtData { return coverArtData; }
- (float)volumeValue { return 0.5f; }
- (double)elapsedPlaybackTimeValue { return 0.0; }
- (double)trackDurationValue { return 0.0; }
- (BOOL)isConnected { return trackName != nil; }
- (BOOL)isPlaying { return NO; }
- (NSString *)connectedDeviceName { return nil; }
- (void)stopReceiver {}
- (void)dealloc {
    [trackName release];
    [artistName release];
    [albumName release];
    [coverArtData release];
    [super dealloc];
}
@end

static void SendPending(AirPlayReceiverAppDelegate *delegate) {
    [NSObject cancelPreviousPerformRequestsWithTarget:delegate
                                             selector:@selector(sendPendingGrowlNotification)
                                               object:nil];
    [delegate performSelector:@selector(sendPendingGrowlNotification)];
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    RAOPReceiver *receiver = [[RAOPReceiver alloc] init];
    GrowlNotifier *notifier = [[GrowlNotifier alloc] init];
    AirPlayReceiverAppDelegate *delegate = [[AirPlayReceiverAppDelegate alloc] init];
    [delegate setValue:receiver forKey:@"receiver"];
    [delegate setValue:notifier forKey:@"growlNotifier"];
    [receiver release];
    [notifier release];
    [delegate buildUI];
    SendPending(delegate);
    BOOL passed = notificationCount == 0;

    NSImage *artwork = [[[NSImage alloc] initWithSize:NSMakeSize(10, 10)] autorelease];
    [artwork lockFocus];
    [[NSColor redColor] set];
    NSRectFill(NSMakeRect(0, 0, 10, 10));
    [artwork unlockFocus];
    [receiver setTestTitle:@"Track" artist:nil album:nil artwork:nil];
    [delegate refreshUI];
    [receiver setTestTitle:@"Track" artist:@"Artist" album:@"Album" artwork:[artwork TIFFRepresentation]];
    [delegate refreshUI];
    SendPending(delegate);
    passed = passed && notificationCount == 1 && [notifiedTitle isEqualToString:@"Track"] &&
        [notifiedArtist isEqualToString:@"Artist"] && [notifiedAlbum isEqualToString:@"Album"] && notifiedArtwork;

    [delegate refreshUI];
    SendPending(delegate);
    passed = passed && notificationCount == 1;

    [receiver setTestTitle:@"Other" artist:@"Artist" album:@"Album" artwork:nil];
    [delegate refreshUI];
    [receiver setTestTitle:@"Track" artist:@"Artist" album:@"Album" artwork:nil];
    [delegate refreshUI];
    SendPending(delegate);
    passed = passed && notificationCount == 1;

    [receiver setTestTitle:nil artist:nil album:nil artwork:nil];
    [delegate refreshUI];
    [receiver setTestTitle:@"Track" artist:@"Artist" album:@"Album" artwork:nil];
    [delegate refreshUI];
    SendPending(delegate);
    passed = passed && notificationCount == 2 && !notifiedArtwork;

    [delegate applicationWillTerminate:[NSNotification notificationWithName:@"TestTermination" object:nil]];
    [delegate release];
    [notifiedTitle release];
    [notifiedArtist release];
    [notifiedAlbum release];
    NSLog(@"Growl track flow tests %@", passed ? @"passed" : @"failed");
    [pool drain];
    return passed ? 0 : 1;
}