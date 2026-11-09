#import "GrowlNotifier.h"

@implementation GrowlNotifier

+ (GrowlNotifier *)sharedNotifier {
    static GrowlNotifier *sharedInstance = nil;
    if (sharedInstance == nil) {
        sharedInstance = [[GrowlNotifier alloc] init];
    }
    return sharedInstance;
}

- (id)init {
    self = [super init];
    if (self != nil) {
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                            selector:@selector(growlDidStart:)
                                                                name:@"Lend Me Some Sugar; I Am Your Neighbor!"
                                                              object:nil];
        [self registerApplication];
    }
    return self;
}

- (void)dealloc {
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)registerApplication {
    NSArray *notifications = [NSArray arrayWithObject:@"Now Playing"];
    NSMutableDictionary *registration = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"PowerPlay", @"ApplicationName",
        notifications, @"AllNotifications",
        notifications, @"DefaultNotifications", nil];
    NSData *iconData = [[NSApp applicationIconImage] TIFFRepresentation];
    if (iconData != nil) {
        [registration setObject:iconData forKey:@"ApplicationIcon"];
    }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"GrowlApplicationRegistrationNotification"
                      object:nil userInfo:registration deliverImmediately:YES];
}

- (void)growlDidStart:(NSNotification *)notification {
    (void)notification;
    [self registerApplication];
}

- (void)notifyTrackTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album image:(NSImage *)image {
    NSString *trackTitle = title;
    if (trackTitle == nil || [trackTitle length] == 0) {
        trackTitle = @"Unknown Track";
    }

    NSString *artistName = artist;
    if (artistName == nil || [artistName length] == 0) {
        artistName = @"AirPlay Source";
    }

    NSString *albumName = album;
    if (albumName == nil || [albumName length] == 0) {
        albumName = @"Unknown Album";
    }

    NSImage *sourceImage = image;
    if (sourceImage == nil || ![sourceImage isValid] ||
        [sourceImage size].width <= 0.0 || [sourceImage size].height <= 0.0) {
        sourceImage = [NSApp applicationIconImage];
    }
    NSData *iconData = nil;
    if (sourceImage != nil && [sourceImage isValid]) {
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
        [icon lockFocus];
        [sourceImage drawInRect:NSMakeRect(0, 0, 64, 64)
                       fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
        [icon unlockFocus];
        iconData = [icon TIFFRepresentation];
        [icon release];
    }
    if (iconData == nil) {
        iconData = [[NSApp applicationIconImage] TIFFRepresentation];
    }

    NSString *description = [NSString stringWithFormat:@"%@\n%@", artistName, albumName];
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"PowerPlay", @"ApplicationName",
        @"Now Playing", @"NotificationName",
        trackTitle, @"NotificationTitle",
        description, @"NotificationDescription", nil];
    if (iconData != nil) {
        [details setObject:iconData forKey:@"NotificationIcon"];
    }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"GrowlNotification"
                      object:nil userInfo:details deliverImmediately:YES];
}

@end
