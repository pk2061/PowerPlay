#import <Cocoa/Cocoa.h>
#import "RAOPReceiver.h"
#import "GrowlNotifier.h"

@class CoverArtView;

#if defined(__OBJC__)
@protocol NSApplicationDelegate;
#endif

@interface AirPlayReceiverAppDelegate : NSObject {
    NSWindow *window;
    NSButton *playPauseButton;
    NSButton *nextButton;
    NSButton *prevButton;
    NSSlider *volumeSlider;
    NSTextField *titleText;
    NSTextField *artistText;
    NSTextField *albumText;
    NSTextField *statusText;
    CoverArtView *coverView;
    RAOPReceiver *receiver;
    GrowlNotifier *growlNotifier;
    NSString *lastGrowlTitle;
}

- (void)buildUI;
- (void)refreshUI;

- (IBAction)togglePlayPause:(id)sender;
- (IBAction)nextTrack:(id)sender;
- (IBAction)previousTrack:(id)sender;
- (IBAction)changeVolume:(id)sender;

@end
