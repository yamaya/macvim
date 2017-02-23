/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */
/*
 * MMWindow
 *
 * A normal window with a (possibly hidden) tabline separator at the top of the
 * content view.
 *
 * The main point of this class is for the window controller to be able to call
 * contentRectForFrameRect: without having to worry about whether the separator
 * is visible or not.
 *
 * This is a bit of a hack, it would be nicer to be able to leave the content
 * view alone, but as it is the tabline separator is a subview of the content
 * view.  Since we want to pretend that the content view does not contain the
 * separator this leads to some dangerous situations.  For instance, calling
 * [window setContentMinSize:size] when the separator is visible results in
 * size != [window contentMinSize], since the latter is one pixel higher than
 * 'size'.
 */

#import "MMWindow.h"
#import "Miscellaneous.h"

#import "CGSInternal/CGSWindow.h"

typedef CGError CGSSetWindowBackgroundBlurRadiusFunction(CGSConnectionID cid, CGSWindowID wid, NSUInteger blur);

static void *GetFunctionByName(NSString *library, char *func)
{
    CFBundleRef bundle;
    CFURLRef bundleURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)library, kCFURLPOSIXPathStyle, true);
    CFStringRef functionName = CFStringCreateWithCString(kCFAllocatorDefault, func, kCFStringEncodingASCII);
    bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL);
    void *f = NULL;
    if (bundle) {
        f = CFBundleGetFunctionPointerForName(bundle, functionName);
        CFRelease(bundle);
    }
    CFRelease(functionName);
    CFRelease(bundleURL);
    return f;
}

static CGSSetWindowBackgroundBlurRadiusFunction* GetCGSSetWindowBackgroundBlurRadiusFunction(void)
{
    static BOOL tried = NO;
    static CGSSetWindowBackgroundBlurRadiusFunction *f = NULL;

    if (!tried) {
        f = GetFunctionByName(@"/System/Library/Frameworks/ApplicationServices.framework", "CGSSetWindowBackgroundBlurRadius");
        tried = YES;
    }
    return f;
}


@implementation MMWindow {
    NSBox       *_tablineSeparator;
}

- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSUInteger)style backing:(NSBackingStoreType)bufferingType defer:(BOOL)flag
{
    self = [super initWithContentRect:rect styleMask:style backing:bufferingType defer:flag];
    if (!self) return nil;

    self.releasedWhenClosed = NO;

    _tablineSeparator = [[NSBox alloc] initWithFrame:(NSRect){
        {0, rect.size.height - 1}, {rect.size.width, 1}
    }];
    _tablineSeparator.boxType = NSBoxSeparator;
    _tablineSeparator.hidden = YES;
    _tablineSeparator.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    self.contentView.autoresizesSubviews = YES;
    [self.contentView addSubview:_tablineSeparator];

    // NOTE: Vim needs to process mouse moved events, so enable them here.
    self.acceptsMouseMovedEvents = YES;

    return self;
}

- (BOOL) canBecomeMainWindow {
    return YES;
}

- (BOOL) canBecomeKeyWindow {
    return YES;
}

- (BOOL)hideTablineSeparator:(BOOL)hide
{
    const BOOL old = _tablineSeparator.isHidden;
    _tablineSeparator.hidden = hide;

    // Return YES if visibility state was toggled, NO if it was unchanged.
    return old != hide;
}

- (NSRect)contentRectForFrameRect:(NSRect)frame
{
    NSRect rect = [super contentRectForFrameRect:frame];
    if (!_tablineSeparator.isHidden)
        --rect.size.height;

    return rect;
}

- (NSRect)frameRectForContentRect:(NSRect)rect
{
    NSRect frame = [super frameRectForContentRect:rect];
    if (!_tablineSeparator.isHidden) ++frame.size.height;

    return frame;
}

- (void)setContentMinSize:(NSSize)size
{
    if (!_tablineSeparator.isHidden) ++size.height;

    [super setContentMinSize:size];
}

- (void)setContentMaxSize:(NSSize)size
{
    if (!_tablineSeparator.isHidden) ++size.height;

    [super setContentMaxSize:size];
}

- (void)setContentSize:(NSSize)size
{
    if (!_tablineSeparator.isHidden) ++size.height;

    [super setContentSize:size];
}

- (void)setBlurRadius:(int)radius
{
    if (radius >= 0) {
        CGSConnectionID con = CGSMainConnectionID();
        if (!con) {
            return;
        }
        CGSSetWindowBackgroundBlurRadiusFunction* f = GetCGSSetWindowBackgroundBlurRadiusFunction();
        if (f) f(con, self.windowNumber, radius);
    }
}

- (void)performClose:(id)sender
{
    id wc = self.windowController;
    if ([wc respondsToSelector:@selector(performClose:)])
        [wc performClose:sender];
    else
        [super performClose:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(vimMenuItemAction:) || item.action == @selector(performClose:))
        return item.tag != 0;
    return YES;
}

- (IBAction)zoom:(id)sender
{
    // NOTE: We shortcut the usual zooming behavior and provide custom zooming
    // in the window controller.

    // (Use performSelector:: to avoid compilation warning.)
    [self.delegate performSelector:@selector(zoom:) withObject:sender];
}

- (IBAction)toggleFullScreen:(id)sender
{
    // HACK! This is an NSWindow method used to enter full-screen on OS X 10.7.
    // We override it so that we can interrupt and pass this on to Vim first.
    // An alternative hack would be to reroute the action message sent by the
    // full-screen button in the top right corner of a window, but there could
    // be other places where this action message is sent from.
    // To get to the original method (and enter Lion full-screen) we need to
    // call realToggleFullScreen: defined below.

    // (Use performSelector:: to avoid compilation warning.)
    [self.delegate performSelector:@selector(invFullScreen:) withObject:nil];
}

- (IBAction)realToggleFullScreen:(id)sender
{
#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    // HACK! See toggleFullScreen: comment above.
    if ([NSWindow instancesRespondToSelector:@selector(toggleFullScreen:)])
        [super toggleFullScreen:sender];
#endif
}

- (void)setToolbar:(NSToolbar *)toolbar
{
    if ([NSUserDefaults.standardUserDefaults boolForKey:MMNoTitleBarWindowKey]) {
        // MacVim can't have toolbar with No title bar setting.
        return;
    }

    [super setToolbar:toolbar];
}

@end // MMWindow
