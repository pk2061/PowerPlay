#import <Cocoa/Cocoa.h>

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int status = NSApplicationMain(argc, (const char **)argv);
    [pool release];
    return status;
}
