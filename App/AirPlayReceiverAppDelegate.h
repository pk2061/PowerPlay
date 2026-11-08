#import <Cocoa/Cocoa.h>
#import "RAOPReceiver.h"
#import "GrowlNotifier.h"

@class CoverArtView;

#if defined(__OBJC__)
@protocol NSApplicationDelegate;
#endif

@interface AirPlayReceiverAppDelegate : NSObject <NSApplicationDelegate> {
    NSWindow *window;
    NSButton *playPauseButton;
    NSButton *nextButton;
    NSButton *prevButton;
    NSSlider *volumeSlider;
    NSTextField *titleText;
    NSTextField *artistText;
    NSTextField *albumText;
    NSTextField *playbackTimeText;
    NSTextField *statusText;
    NSProgressIndicator *playbackProgress;
    CoverArtView *coverView;
    RAOPReceiver *receiver;
    GrowlNotifier *growlNotifier;
    NSString *lastGrowlTitle;
    BOOL showsRemainingTime;
    NSTimer *playbackRefreshTimer;
}

- (void)installApplicationMenu;
- (void)buildUI;
- (void)refreshUI;
- (void)refreshPlaybackProgress:(NSTimer *)timer;

- (IBAction)togglePlayPause:(id)sender;
- (IBAction)nextTrack:(id)sender;
- (IBAction)previousTrack:(id)sender;
- (IBAction)changeVolume:(id)sender;
- (IBAction)togglePlaybackTimeDisplay:(id)sender;

@end
