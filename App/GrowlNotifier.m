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
#if AIRPLAY_GROWL_AVAILABLE
        [self registerApplication];
#endif
    }
    return self;
}

- (void)dealloc {
#if AIRPLAY_GROWL_AVAILABLE
    [GrowlApplicationBridge setGrowlDelegate:nil];
#endif
    [super dealloc];
}

- (void)registerApplication {
#if AIRPLAY_GROWL_AVAILABLE
    [GrowlApplicationBridge setGrowlDelegate:self];
#endif
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
        albumName = @"Now Playing";
    }

#if AIRPLAY_GROWL_AVAILABLE
    NSData *iconData = nil;
    if (image != nil) {
        iconData = [image TIFFRepresentation];
    }

    NSString *description = [NSString stringWithFormat:@"%@\n%@\n%@",
                             artistName,
                             albumName,
                             trackTitle];

    [GrowlApplicationBridge notifyWithTitle:trackTitle
                                 description:description
                            notificationName:@"Now Playing"
                                    iconData:iconData
                                    priority:0
                                    isSticky:NO
                                clickContext:nil];
#else
    (void)artistName;
    (void)albumName;
    (void)image;
#endif
}

@end
