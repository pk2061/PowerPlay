#import <Cocoa/Cocoa.h>
#import "GrowlNotifier.h"

@interface GrowlNotificationRecorder : NSObject {
    NSDictionary *registration;
    NSDictionary *notification;
}
- (void)recordRegistration:(NSNotification *)event;
- (void)recordNotification:(NSNotification *)event;
- (NSDictionary *)registration;
- (NSDictionary *)notification;
- (void)clearNotification;
@end

@implementation GrowlNotificationRecorder
- (void)recordRegistration:(NSNotification *)event {
    [registration release];
    registration = [[event userInfo] copy];
}
- (void)recordNotification:(NSNotification *)event {
    [notification release];
    notification = [[event userInfo] copy];
}
- (NSDictionary *)registration { return registration; }
- (NSDictionary *)notification { return notification; }
- (void)clearNotification {
    [notification release];
    notification = nil;
}
- (void)dealloc {
    [registration release];
    [notification release];
    [super dealloc];
}
@end

static NSImage *TestImage(NSColor *color) {
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(80, 80)] autorelease];
    [image lockFocus];
    [color set];
    NSRectFill(NSMakeRect(0, 0, 80, 80));
    [image unlockFocus];
    return image;
}

static void WaitForNotifications(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
}

static BOOL IconHasColor(NSData *data, BOOL expectRed) {
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:data];
    if (bitmap == nil || [bitmap pixelsWide] != 64 || [bitmap pixelsHigh] != 64) {
        return NO;
    }
    NSColor *color = [[bitmap colorAtX:32 y:32] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    return color != nil && (expectRed ? [color redComponent] > [color blueComponent] :
                                       [color blueComponent] > [color redComponent]);
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    [NSApp setApplicationIconImage:TestImage([NSColor blueColor])];

    GrowlNotificationRecorder *recorder = [[GrowlNotificationRecorder alloc] init];
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:recorder selector:@selector(recordRegistration:)
                   name:@"GrowlApplicationRegistrationNotification" object:nil];
    [center addObserver:recorder selector:@selector(recordNotification:)
                   name:@"GrowlNotification" object:nil];

    GrowlNotifier *notifier = [[GrowlNotifier alloc] init];
    WaitForNotifications();
    NSDictionary *registration = [recorder registration];
    BOOL passed = [[registration objectForKey:@"ApplicationName"] isEqualToString:@"PowerPlay"] &&
        [[registration objectForKey:@"DefaultNotifications"] containsObject:@"Now Playing"];

    [notifier notifyTrackTitle:@"Track" artist:@"Artist" album:@"Album" image:TestImage([NSColor redColor])];
    WaitForNotifications();
    NSDictionary *notification = [recorder notification];
    passed = passed && [[notification objectForKey:@"NotificationTitle"] isEqualToString:@"Track"] &&
        [[notification objectForKey:@"NotificationDescription"] isEqualToString:@"Artist\nAlbum"] &&
        IconHasColor([notification objectForKey:@"NotificationIcon"], YES);

    [recorder clearNotification];
    [notifier notifyTrackTitle:@"Next" artist:nil album:nil image:nil];
    WaitForNotifications();
    notification = [recorder notification];
    passed = passed && [[notification objectForKey:@"NotificationTitle"] isEqualToString:@"Next"] &&
        IconHasColor([notification objectForKey:@"NotificationIcon"], NO);

    [recorder clearNotification];
    NSImage *invalidImage = [[[NSImage alloc] init] autorelease];
    [notifier notifyTrackTitle:@"Invalid Artwork" artist:nil album:nil image:invalidImage];
    WaitForNotifications();
    notification = [recorder notification];
    passed = passed && [[notification objectForKey:@"NotificationTitle"] isEqualToString:@"Invalid Artwork"] &&
        IconHasColor([notification objectForKey:@"NotificationIcon"], NO);

    [center removeObserver:recorder];
    [notifier release];
    [recorder release];
    NSLog(@"Growl notification tests %@", passed ? @"passed" : @"failed");
    [pool drain];
    return passed ? 0 : 1;
}