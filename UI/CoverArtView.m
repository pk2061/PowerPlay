#import "CoverArtView.h"

@implementation CoverArtView

- (id)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        coverImage = nil;
        borderColor = [[NSColor darkGrayColor] retain];
    }
    return self;
}

- (void)dealloc {
    [coverImage release];
    [borderColor release];
    [super dealloc];
}

- (void)setImage:(NSImage *)image {
    [coverImage release];
    coverImage = [image retain];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor whiteColor] set];
    NSRectFill(dirtyRect);

    [[NSColor darkGrayColor] set];
    NSFrameRect([self bounds]);

    if (coverImage != nil) {
        NSRect imageRect = NSMakeRect(4, 4, [self bounds].size.width - 8, [self bounds].size.height - 8);
        [coverImage drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
    } else {
        NSString *label = @"Cover Art";
        NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSFont systemFontOfSize:14], NSFontAttributeName,
                              [NSColor grayColor], NSForegroundColorAttributeName,
                              nil];
        NSSize size = [label sizeWithAttributes:attrs];
        NSPoint p = NSMakePoint((NSWidth([self bounds]) - size.width) / 2.0,
                                (NSHeight([self bounds]) - size.height) / 2.0);
        [label drawAtPoint:p withAttributes:attrs];
    }
}

@end
