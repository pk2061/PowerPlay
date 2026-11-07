#import <Cocoa/Cocoa.h>
#import "AirPlayReceiverAppDelegate.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    AirPlayReceiverAppDelegate *delegate = [[AirPlayReceiverAppDelegate alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run];
    NSLog(@"PowerPlay: NSApplication run returned");
    [delegate release];
    [pool release];
    return 0;
}
