#import "AirPlayReceiverAppDelegate.h"
#import "CoverArtView.h"

@class PowerPlayScrollingTextField;

@interface PowerPlayScrollTimerTarget : NSObject {
    PowerPlayScrollingTextField *field;
}
- (id)initWithField:(PowerPlayScrollingTextField *)textField;
- (void)setField:(PowerPlayScrollingTextField *)textField;
- (void)scrollTimerFired:(NSTimer *)timer;
@end

@interface PowerPlayScrollingTextField : NSTextField {
    NSTimer *scrollTimer;
    PowerPlayScrollTimerTarget *scrollTimerTarget;
    float scrollTextWidth;
    float scrollOffset;
    NSInteger scrollDirection;
    NSUInteger scrollPauseTicks;
}
- (void)updateScrollTimer;
- (void)advanceScroll:(NSTimer *)timer;
@end

@implementation PowerPlayScrollTimerTarget

- (id)initWithField:(PowerPlayScrollingTextField *)textField {
    self = [super init];
    if (self != nil) {
        field = textField;
    }
    return self;
}

- (void)setField:(PowerPlayScrollingTextField *)textField {
    field = textField;
}

- (void)scrollTimerFired:(NSTimer *)timer {
    [field advanceScroll:timer];
}

@end

@implementation PowerPlayScrollingTextField

- (id)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        scrollTimer = nil;
        scrollTextWidth = 0.0;
        scrollOffset = 0.0;
        scrollDirection = 1;
        scrollPauseTicks = 20;
        if (scrollTimerTarget == nil) {
            scrollTimerTarget = [[PowerPlayScrollTimerTarget alloc] initWithField:self];
        }
        [self updateScrollTimer];
    }
    return self;
}

- (void)dealloc {
    [scrollTimer invalidate];
    [scrollTimer release];
    [scrollTimerTarget setField:nil];
    [scrollTimerTarget release];
    [super dealloc];
}

- (void)setStringValue:(NSString *)value {
    NSString *oldValue = [self stringValue];
    [super setStringValue:value];
    if (![oldValue isEqualToString:value]) {
        scrollOffset = 0.0;
        scrollDirection = 1;
        scrollPauseTicks = 20;
        [self updateScrollTimer];
        [self setNeedsDisplay:YES];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateScrollTimer];
}

- (void)setFont:(NSFont *)font {
    [super setFont:font];
    [self updateScrollTimer];
}

- (NSDictionary *)scrollTextAttributes {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    NSFont *font = [self font];
    NSColor *color = [self textColor];
    [attributes setObject:font == nil ? [NSFont systemFontOfSize:12.0] : font
                   forKey:NSFontAttributeName];
    [attributes setObject:color == nil ? [NSColor blackColor] : color
                   forKey:NSForegroundColorAttributeName];
    return attributes;
}

- (void)updateScrollTimer {
    NSString *value = [self stringValue];
    if (value == nil || [value length] == 0) {
        scrollTextWidth = 0.0;
    } else {
        scrollTextWidth = [value sizeWithAttributes:[self scrollTextAttributes]].width;
    }

    float maximumOffset = scrollTextWidth - NSWidth([self bounds]);
    if (maximumOffset <= 0.0) {
        scrollOffset = 0.0;
        [scrollTimer invalidate];
        [scrollTimer release];
        scrollTimer = nil;
        return;
    }

    if (scrollTimer == nil) {
        if (scrollTimerTarget == nil) {
            scrollTimerTarget = [[PowerPlayScrollTimerTarget alloc] initWithField:self];
        }
        scrollTimer = [[NSTimer scheduledTimerWithTimeInterval:0.04
                                                        target:scrollTimerTarget
                                                      selector:@selector(scrollTimerFired:)
                                                      userInfo:nil
                                                       repeats:YES] retain];
    }
}

- (void)advanceScroll:(NSTimer *)timer {
    (void)timer;
    if (scrollPauseTicks > 0) {
        scrollPauseTicks--;
        return;
    }

    float maximumOffset = scrollTextWidth - NSWidth([self bounds]);
    scrollOffset += (float)scrollDirection;
    if (scrollOffset >= maximumOffset) {
        scrollOffset = maximumOffset;
        scrollDirection = -1;
        scrollPauseTicks = 20;
    } else if (scrollOffset <= 0.0) {
        scrollOffset = 0.0;
        scrollDirection = 1;
        scrollPauseTicks = 20;
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSString *value = [self stringValue];
    if (value == nil || scrollTextWidth <= NSWidth([self bounds])) {
        [super drawRect:dirtyRect];
        return;
    }

    NSDictionary *attributes = [self scrollTextAttributes];
    NSSize textSize = [value sizeWithAttributes:attributes];
    NSRect bounds = [self bounds];
    NSPoint textPoint = NSMakePoint(NSMinX(bounds) - scrollOffset,
        NSMinY(bounds) + (NSHeight(bounds) - textSize.height) / 2.0);

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(bounds);
    [value drawAtPoint:textPoint withAttributes:attributes];
    [NSGraphicsContext restoreGraphicsState];
}

@end

@interface PowerPlayClickableTextField : NSTextField
@end

@implementation PowerPlayClickableTextField

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if ([self target] != nil && [self action] != NULL) {
        [NSApp sendAction:[self action] to:[self target] from:self];
    }
}

@end

@implementation AirPlayReceiverAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"PowerPlay: applicationDidFinishLaunching");
    [self installApplicationMenu];
    receiver = [[RAOPReceiver alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(receiverMetadataDidChange:)
                                                   name:PowerPlayMetadataDidChangeNotification
                                                 object:receiver];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                             selector:@selector(receiverMetadataDidChange:)
                                                                                                     name:PowerPlayVolumeDidChangeNotification
                                                                                                 object:receiver];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                             selector:@selector(receiverMetadataDidChange:)
                                                                                                     name:PowerPlayPlaybackProgressDidChangeNotification
                                                                                                 object:receiver];
    growlNotifier = [[GrowlNotifier alloc] init];
    lastGrowlTrack = nil;
    pendingGrowlTrack = nil;
    [self buildUI];
    [receiver startReceiver];
}

- (void)installApplicationMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSMenuItem *applicationMenuItem = [[NSMenuItem alloc] initWithTitle:@"PowerPlay"
                                                               action:nil
                                                        keyEquivalent:@""];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"PowerPlay"];

    NSMenuItem *aboutItem = [applicationMenu addItemWithTitle:@"About PowerPlay"
                                                       action:@selector(orderFrontStandardAboutPanel:)
                                                keyEquivalent:@""];
    [aboutItem setTarget:NSApp];
    [applicationMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *showWindowItem = [applicationMenu addItemWithTitle:@"Show PowerPlay Window"
                                       action:@selector(showMainWindow:)
                                   keyEquivalent:@""];
        [showWindowItem setTarget:self];
        [applicationMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hideItem = [applicationMenu addItemWithTitle:@"Hide PowerPlay"
                                                      action:@selector(hide:)
                                               keyEquivalent:@"h"];
    [hideItem setTarget:NSApp];

    NSMenuItem *hideOthersItem = [applicationMenu addItemWithTitle:@"Hide Others"
                                                           action:@selector(hideOtherApplications:)
                                                    keyEquivalent:@"h"];
    [hideOthersItem setTarget:NSApp];
    [hideOthersItem setKeyEquivalentModifierMask:(NSCommandKeyMask | NSAlternateKeyMask)];

    NSMenuItem *showAllItem = [applicationMenu addItemWithTitle:@"Show All"
                                                         action:@selector(unhideAllApplications:)
                                                  keyEquivalent:@""];
    [showAllItem setTarget:NSApp];
    [applicationMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [applicationMenu addItemWithTitle:@"Quit PowerPlay"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];

    [applicationMenuItem setSubmenu:applicationMenu];
    [mainMenu addItem:applicationMenuItem];
    [NSApp setMainMenu:mainMenu];

    [applicationMenu release];
    [applicationMenuItem release];
    [mainMenu release];
}

- (void)buildUI {
    NSRect frame = NSMakeRect(0, 0, 560, 360);
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask)
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
        [window setReleasedWhenClosed:NO];
    [window setTitle:@"PowerPlay"];
    [window center];

    NSView *content = [window contentView];

    coverView = [[CoverArtView alloc] initWithFrame:NSMakeRect(20, 90, 180, 180)];
    [content addSubview:coverView];

    titleText = [[PowerPlayScrollingTextField alloc] initWithFrame:NSMakeRect(220, 220, 300, 28)];
    [titleText setEditable:NO];
    [titleText setBordered:NO];
    [titleText setDrawsBackground:NO];
    [titleText setFont:[NSFont boldSystemFontOfSize:18]];
    [titleText setTextColor:[NSColor blackColor]];
    [titleText setStringValue:@"No source connected"];
    [content addSubview:titleText];

    artistText = [[PowerPlayScrollingTextField alloc] initWithFrame:NSMakeRect(220, 190, 300, 24)];
    [artistText setEditable:NO];
    [artistText setBordered:NO];
    [artistText setDrawsBackground:NO];
    [artistText setFont:[NSFont systemFontOfSize:14]];
    [artistText setTextColor:[NSColor darkGrayColor]];
    [artistText setStringValue:@"AirPlay Source"];
    [content addSubview:artistText];

    albumText = [[PowerPlayScrollingTextField alloc] initWithFrame:NSMakeRect(220, 165, 300, 22)];
    [albumText setEditable:NO];
    [albumText setBordered:NO];
    [albumText setDrawsBackground:NO];
    [albumText setFont:[NSFont systemFontOfSize:12]];
    [albumText setTextColor:[NSColor grayColor]];
    [albumText setStringValue:@"Current Track"];
    [content addSubview:albumText];

    playbackProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(220, 141, 208, 14)];
    [playbackProgress setStyle:NSProgressIndicatorBarStyle];
    [playbackProgress setIndeterminate:NO];
    [playbackProgress setMinValue:0.0];
    [playbackProgress setMaxValue:1.0];
    [playbackProgress setDoubleValue:0.0];
    [content addSubview:playbackProgress];

    playbackTimeText = [[PowerPlayClickableTextField alloc] initWithFrame:NSMakeRect(438, 139, 112, 18)];
    [playbackTimeText setEditable:NO];
    [playbackTimeText setBordered:NO];
    [playbackTimeText setDrawsBackground:NO];
    [playbackTimeText setFont:[NSFont systemFontOfSize:10]];
    [playbackTimeText setTextColor:[NSColor grayColor]];
    [playbackTimeText setAlignment:NSRightTextAlignment];
    [[playbackTimeText cell] setWraps:NO];
    [[playbackTimeText cell] setScrollable:YES];
    [playbackTimeText setTarget:self];
    [playbackTimeText setAction:@selector(togglePlaybackTimeDisplay:)];
    [playbackTimeText setStringValue:@"0:00 / 0:00"];
    [content addSubview:playbackTimeText];

    statusText = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 30, 520, 22)];
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
        playbackRefreshTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                                                                                             target:self
                                                                                                                         selector:@selector(refreshPlaybackProgress:)
                                                                                                                         userInfo:nil
                                                                                                                            repeats:YES] retain];
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
        album = @"";
    }

    NSImage *notificationImage = nil;
    NSData *art = [receiver coverArtData];
    if (art != nil && [art length] > 0) {
        notificationImage = [[NSImage alloc] initWithData:art];
        [coverView setImage:notificationImage];
    } else {
        NSImage *placeholder = [[NSImage alloc] initWithSize:NSMakeSize(180, 180)];
        [placeholder lockFocus];
        NSColor *light = [NSColor colorWithCalibratedRed:0.88 green:0.88 blue:0.90 alpha:1.0];
        NSColor *dark = [NSColor colorWithCalibratedRed:0.74 green:0.76 blue:0.80 alpha:1.0];
        [light set];
        NSRectFill(NSMakeRect(0, 0, 180, 180));
        [dark set];
        NSRectFill(NSMakeRect(0, 0, 180, 10));
        [[NSColor darkGrayColor] set];
        NSFrameRect(NSMakeRect(0, 0, 180, 180));
        [placeholder unlockFocus];
        [coverView setImage:placeholder];
        [placeholder release];
    }

    [notificationImage release];

    NSString *trackTitle = [receiver trackName];
    if ([trackTitle length] == 0) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendPendingGrowlNotification) object:nil];
        [pendingGrowlTrack release];
        pendingGrowlTrack = nil;
        [lastGrowlTrack release];
        lastGrowlTrack = nil;
    } else {
        NSDictionary *track = [NSDictionary dictionaryWithObjectsAndKeys:
            trackTitle, @"title", artist, @"artist", album, @"album", nil];
        if (![track isEqualToDictionary:pendingGrowlTrack]) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendPendingGrowlNotification) object:nil];
            [pendingGrowlTrack release];
            pendingGrowlTrack = nil;
            if (![track isEqualToDictionary:lastGrowlTrack]) {
                pendingGrowlTrack = [track copy];
                [self performSelector:@selector(sendPendingGrowlNotification) withObject:nil afterDelay:1.5];
            }
        }
    }

    [volumeSlider setFloatValue:[receiver volumeValue]];
    [titleText setStringValue:title];
    [artistText setStringValue:artist];
    [albumText setStringValue:album];

    [self refreshPlaybackProgress:nil];

    if ([receiver isConnected]) {
        NSString *connectedName = [receiver connectedDeviceName];
        if (connectedName == nil || [connectedName length] == 0) {
            connectedName = @"AirPlay device";
        }
        [statusText setStringValue:[NSString stringWithFormat:@"Playing via AirPlay from %@", connectedName]];
        [playPauseButton setTitle:[receiver isPlaying] ? @"Pause" : @"Play"];
    } else if ([receiver isPlaying]) {
        [statusText setStringValue:@"Playing via AirPlay"];
        [playPauseButton setTitle:@"Pause"];
    } else {
        [statusText setStringValue:[receiver isConnected] ? @"Ready" : @"Waiting for AirPlay source..."];
        [playPauseButton setTitle:@"Play"];
    }
}

- (void)refreshPlaybackProgress:(NSTimer *)timer {
    (void)timer;
    double elapsed = [receiver elapsedPlaybackTimeValue];
    double duration = [receiver trackDurationValue];
    unsigned long elapsedSeconds = elapsed > 0.0 ? (unsigned long)elapsed : 0;
    unsigned long durationSeconds = duration > 0.0 ? (unsigned long)duration : 0;
    unsigned long displayedDuration = durationSeconds;
    NSString *durationPrefix = @"";
    if (showsRemainingTime && durationSeconds > 0) {
        displayedDuration = elapsedSeconds < durationSeconds ? durationSeconds - elapsedSeconds : 0;
        durationPrefix = @"-";
    }
    NSString *durationText = [NSString stringWithFormat:@"%@%lu:%02lu", durationPrefix,
        displayedDuration / 60, displayedDuration % 60];
    [playbackTimeText setStringValue:[NSString stringWithFormat:@"%lu:%02lu / %@",
        elapsedSeconds / 60, elapsedSeconds % 60, durationText]];
    BOOL playing = [receiver isPlaying];
    if (duration > 0.0) {
        if ([playbackProgress isIndeterminate]) {
            [playbackProgress stopAnimation:nil];
            [playbackProgress setIndeterminate:NO];
        }
        double progress = elapsed / duration;
        if (progress < 0.0) progress = 0.0;
        if (progress > 1.0) progress = 1.0;
        [playbackProgress setDoubleValue:progress];
    } else if (playing) {
        if (![playbackProgress isIndeterminate]) {
            [playbackProgress setIndeterminate:YES];
            [playbackProgress startAnimation:nil];
        }
    } else {
        if ([playbackProgress isIndeterminate]) {
            [playbackProgress stopAnimation:nil];
            [playbackProgress setIndeterminate:NO];
        }
        [playbackProgress setDoubleValue:0.0];
    }
}

- (void)receiverMetadataDidChange:(NSNotification *)notification {
    (void)notification;
    [self performSelectorOnMainThread:@selector(refreshUI)
                           withObject:nil
                        waitUntilDone:NO];
}

- (void)sendPendingGrowlNotification {
    if (pendingGrowlTrack == nil) {
        return;
    }
    NSData *artwork = [receiver coverArtData];
    NSImage *image = artwork == nil ? nil : [[NSImage alloc] initWithData:artwork];
    [growlNotifier notifyTrackTitle:[pendingGrowlTrack objectForKey:@"title"]
                            artist:[pendingGrowlTrack objectForKey:@"artist"]
                             album:[pendingGrowlTrack objectForKey:@"album"]
                             image:image];
    [image release];
    [lastGrowlTrack release];
    lastGrowlTrack = pendingGrowlTrack;
    pendingGrowlTrack = nil;
}

- (IBAction)showMainWindow:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    if ([window isMiniaturized]) {
        [window deminiaturize:nil];
    }
    [window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)application;
    (void)hasVisibleWindows;
    [self showMainWindow:nil];
    return YES;
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

- (IBAction)togglePlaybackTimeDisplay:(id)sender {
    (void)sender;
    showsRemainingTime = !showsRemainingTime;
    [self refreshUI];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"PowerPlay: applicationWillTerminate");
    [playbackRefreshTimer invalidate];
    [playbackRefreshTimer release];
    playbackRefreshTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                                                                        name:PowerPlayMetadataDidChangeNotification
                                                                                                    object:receiver];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                                                                        name:PowerPlayVolumeDidChangeNotification
                                                                                                    object:receiver];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                                                                        name:PowerPlayPlaybackProgressDidChangeNotification
                                                                                                    object:receiver];
    [receiver stopReceiver];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendPendingGrowlNotification) object:nil];
    [growlNotifier release];
    [lastGrowlTrack release];
    [pendingGrowlTrack release];
    [receiver release];
}

@end
