#import "MMScroller.h"
#import "MMVimView.h"
#import "MMWindowController.h"
#import "MMVimController.h"

@implementation MMScroller
@synthesize range = _range, type = _type, identifier = _identifier;

- (instancetype)initWithIdentifier:(int32_t)ident type:(MMScrollerType)type
{
    // HACK! NSScroller creates a horizontal scroller if it is init'ed with a
    // frame whose with exceeds its height; so create a bogus rect and pass it
    // to initWithFrame.
    const NSRect frame = type == MMScrollerTypeBottom ? NSMakeRect(0, 0, 1, 0) : NSMakeRect(0, 0, 0, 1);

    self = [super initWithFrame:frame];
    if (!self) return nil;

    _identifier = ident;
    _type = type;
    self.hidden = YES;
    self.enabled = YES;
    self.autoresizingMask = NSViewNotSizable;

    return self;
}

- (void)scrollWheel:(NSEvent *)event
{
    // HACK! Pass message on to the text view.
    NSView *vimView = [self superview];
    if ([vimView isKindOfClass:[MMVimView class]])
        [[(MMVimView*)vimView textView] scrollWheel:event];
}

- (void)mouseDown:(NSEvent *)event
{
    // TODO: This is an ugly way of getting the connection to the backend.
    NSConnection *connection = nil;
    id wc = [[self window] windowController];
    if ([wc isKindOfClass:[MMWindowController class]]) {
        MMVimController *vc = [(MMWindowController*)wc vimController];
        id proxy = [vc backendProxy];
        connection = [(NSDistantObject*)proxy connectionForProxy];
    }

    // NOTE: The scroller goes into "event tracking mode" when the user clicks
    // (and holds) the mouse button.  We have to manually add the backend
    // connection to this mode while the mouse button is held, else DO messages
    // from Vim will not be processed until the mouse button is released.
    [connection addRequestMode:NSEventTrackingRunLoopMode];
    [super mouseDown:event];
    [connection removeRequestMode:NSEventTrackingRunLoopMode];
}

@end
