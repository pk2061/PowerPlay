#import <Cocoa/Cocoa.h>

@interface GrowlNotifier : NSObject {
}

+ (GrowlNotifier *)sharedNotifier;
- (void)registerApplication;
- (void)notifyTrackTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album image:(NSImage *)image;

@end
