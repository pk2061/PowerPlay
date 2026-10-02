#import "AirPlayReceiverAppDelegate.h"
#import "CoverArtView.h"

@implementation AirPlayReceiverAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    receiver = [[RAOPReceiver alloc] init];
    growlNotifier = [[GrowlNotifier alloc] init];
    lastGrowlTitle = nil;
    [self buildUI];
    [receiver startBrowsing];
}

- (void)buildUI {
    NSRect frame = NSMakeRect(0, 0, 560, 360);
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask)
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"PowerPlay"];
    [window center];

    NSView *content = [window contentView];

    coverView = [[CoverArtView alloc] initWithFrame:NSMakeRect(20, 90, 180, 180)];
    [content addSubview:coverView];

    titleText = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 220, 300, 28)];
    [titleText setEditable:NO];
    [titleText setBordered:NO];
    [titleText setDrawsBackground:NO];
    [titleText setFont:[NSFont boldSystemFontOfSize:18]];
    [titleText setTextColor:[NSColor blackColor]];
    [titleText setStringValue:@"No source connected"];
    [content addSubview:titleText];

    artistText = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 190, 300, 24)];
    [artistText setEditable:NO];
    [artistText setBordered:NO];
    [artistText setDrawsBackground:NO];
    [artistText setFont:[NSFont systemFontOfSize:14]];
    [artistText setTextColor:[NSColor darkGrayColor]];
    [artistText setStringValue:@"AirPlay Source"];
    [content addSubview:artistText];

    albumText = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 165, 300, 22)];
    [albumText setEditable:NO];
    [albumText setBordered:NO];
    [albumText setDrawsBackground:NO];
    [albumText setFont:[NSFont systemFontOfSize:12]];
    [albumText setTextColor:[NSColor grayColor]];
    [albumText setStringValue:@"Current Track"];
    [content addSubview:albumText];

    statusText = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 30, 300, 22)];
    [statusText setEditable:NO];
    [statusText setBordered:NO];
    [statusText setDrawsBackground:NO];
    [statusText setFont:[NSFont systemFontOfSize:11]];
    [statusText setTextColor:[NSColor grayColor]];
    [statusText setStringValue:@"Waiting for AirPlay source..."];
    [content addSubview:statusText];

    volumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(220, 110, 180, 24)];
    [volumeSlider setMinValue:0.0];
    [volumeSlider setMaxValue:1.0];
    [volumeSlider setFloatValue:0.5];
    [volumeSlider setTarget:self];
    [volumeSlider setAction:@selector(changeVolume:)];
    [content addSubview:volumeSlider];

    playPauseButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 70, 90, 28)];
    [playPauseButton setTitle:@"Play"];
    [playPauseButton setTarget:self];
    [playPauseButton setAction:@selector(togglePlayPause:)];
    [content addSubview:playPauseButton];

    nextButton = [[NSButton alloc] initWithFrame:NSMakeRect(320, 70, 90, 28)];
    [nextButton setTitle:@"Next"];
    [nextButton setTarget:self];
    [nextButton setAction:@selector(nextTrack:)];
    [content addSubview:nextButton];

    prevButton = [[NSButton alloc] initWithFrame:NSMakeRect(420, 70, 90, 28)];
    [prevButton setTitle:@"Prev"];
    [prevButton setTarget:self];
    [prevButton setAction:@selector(previousTrack:)];
    [content addSubview:prevButton];

    [window makeKeyAndOrderFront:nil];
    [self refreshUI];
}

- (void)refreshUI {
    NSString *title = [receiver currentTitle];
    if (title == nil || [title length] == 0) {
        title = @"No source connected";
    }

    NSString *artist = [receiver artistName];
    if (artist == nil || [artist length] == 0) {
        artist = @"AirPlay Source";
    }

    NSString *album = [receiver albumName];
    if (album == nil || [album length] == 0) {
        album = @"Current Track";
    }

    NSImage *notificationImage = nil;
    NSData *art = [receiver coverArtData];
    if (art != nil && [art length] > 0) {
        notificationImage = [[NSImage alloc] initWithData:art];
        [coverView setImage:notificationImage];
    } else {
        NSImage *placeholder = [[NSImage alloc] initWithSize:NSMakeSize(180, 180)];
        [placeholder lockFocus];
        NSGradient *gradient = [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.88 green:0.88 blue:0.90 alpha:1.0]
                                                          endingColor:[NSColor colorWithCalibratedRed:0.74 green:0.76 blue:0.80 alpha:1.0]] autorelease];
        [gradient drawInRect:NSMakeRect(0, 0, 180, 180) angle:90.0];
        [[NSColor darkGrayColor] set];
        NSFrameRect(NSMakeRect(0, 0, 180, 180));
        [placeholder unlockFocus];
        [coverView setImage:placeholder];
        [placeholder release];
    }

    if (growlNotifier != nil && [title length] > 0 && ![title isEqualToString:@"No source connected"] && ![title isEqualToString:lastGrowlTitle]) {
        [growlNotifier notifyTrackTitle:title artist:artist album:album image:notificationImage];
        [lastGrowlTitle release];
        lastGrowlTitle = [title copy];
    }

    [notificationImage release];

    [volumeSlider setFloatValue:[receiver volumeValue]];
    [titleText setStringValue:title];
    [artistText setStringValue:artist];
    [albumText setStringValue:album];

    if ([receiver isPlaying]) {
        [statusText setStringValue:@"Playing via AirPlay"];
        [playPauseButton setTitle:@"Pause"];
    } else {
        [statusText setStringValue:[receiver isConnected] ? @"Ready" : @"Waiting for AirPlay source..."];
        [playPauseButton setTitle:@"Play"];
    }
}

- (IBAction)togglePlayPause:(id)sender {
    if ([receiver isPlaying]) {
        [receiver pause];
    } else {
        [receiver play];
    }
    [self refreshUI];
}

- (IBAction)nextTrack:(id)sender {
    [receiver nextTrack];
}

- (IBAction)previousTrack:(id)sender {
    [receiver previousTrack];
}

- (IBAction)changeVolume:(id)sender {
    [receiver setVolume:[volumeSlider floatValue]];
    [self refreshUI];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [receiver stopBrowsing];
    [growlNotifier release];
    [lastGrowlTitle release];
    [receiver release];
}

@end
