#import <Cocoa/Cocoa.h>

#ifndef AIRPLAY_GROWL_AVAILABLE
#define AIRPLAY_GROWL_AVAILABLE 0
#endif

#if AIRPLAY_GROWL_AVAILABLE
#import <Growl/Growl.h>
#endif

#if AIRPLAY_GROWL_AVAILABLE
@interface GrowlNotifier : NSObject <GrowlApplicationBridgeDelegate> {
#else
@interface GrowlNotifier : NSObject {
#endif
}

+ (GrowlNotifier *)sharedNotifier;
- (void)registerApplication;
- (void)notifyTrackTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album image:(NSImage *)image;

@end
