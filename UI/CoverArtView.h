#import <Cocoa/Cocoa.h>

@interface CoverArtView : NSView {
    NSImage *coverImage;
    NSColor *borderColor;
}

- (void)setImage:(NSImage *)image;

@end
