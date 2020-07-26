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
 * MMWindowController
 *
 * Handles resizing of windows, acts as an mediator between MMVimView and
 * MMVimController.
 *
 * Resizing in windowed mode:
 *
 * In windowed mode resizing can occur either due to the window frame changing
 * size (e.g. when the user drags to resize), or due to Vim changing the number
 * of (rows,columns).  The former case is dealt with by letting the vim view
 * fill the entire content view when the window has resized.  In the latter
 * case we ensure that vim view fits on the screen.
 *
 * The vim view notifies Vim if the number of (rows,columns) does not match the
 * current number whenver the view size is about to change.  Upon receiving a
 * dimension change message, Vim notifies the window controller and the window
 * resizes.  However, the window is never resized programmatically during a
 * live resize (in order to avoid jittering).
 *
 * The window size is constrained to not become too small during live resize,
 * and it is also constrained to always fit an integer number of
 * (rows,columns).
 *
 * In windowed mode we have to manually draw a tabline separator (due to bugs
 * in the way Cocoa deals with the toolbar separator) when certain conditions
 * are met.  The rules for this are as follows:
 *
 *   Tabline visible & Toolbar visible  =>  Separator visible
 *   =====================================================================
 *         NO        &        NO        =>  YES, if the window is textured
 *                                           NO, otherwise
 *         NO        &       YES        =>  YES
 *        YES        &        NO        =>   NO
 *        YES        &       YES        =>   NO
 *
 *
 * Resizing in custom full-screen mode:
 *
 * The window never resizes since it fills the screen, however the vim view may
 * change size, e.g. when the user types ":set lines=60", or when a scrollbar
 * is toggled.
 *
 * It is ensured that the vim view never becomes larger than the screen size
 * and that it always stays in the center of the screen.
 *
 *
 * Resizing in native full-screen mode (Mac OS X 10.7+):
 *
 * The window is always kept centered and resizing works more or less the same
 * way as in windowed mode.
 *  
 */

#import "MMAppController.h"
#import "MMFindReplaceController.h"
#import "MMFullScreenWindow.h"
#import "MMVimController.h"
#import "MMVimView.h"
#import "MMWindow.h"
#import "MMWindowController.h"
#import "Miscellaneous.h"
#import <PSMTabBarControl/PSMTabBarControl.h>


// These have to be the same as in option.h
#define FUOPT_MAXVERT         0x001
#define FUOPT_MAXHORZ         0x002
#define FUOPT_BGCOLOR_HLGROUP 0x004


@interface MMWindowController (Private)
- (NSSize)contentSize;
- (void)resizeWindowToFitContentSize:(NSSize)contentSize keepOnScreen:(BOOL)onScreen;
- (NSSize)constrainContentSizeToScreenSize:(NSSize)contentSize;
- (NSRect)constrainFrame:(NSRect)frame;
- (void)updateResizeConstraints;
- (NSTabViewItem *)addNewTabViewItem;
- (BOOL)askBackendForStarRegister:(NSPasteboard *)pb;
- (void)updateTablineSeparator;
- (void)hideTablineSeparator:(BOOL)hide;
- (void)doFindNext:(BOOL)next;
- (void)updateToolbar;
- (BOOL)maximizeWindow:(int)options;
- (void)applicationDidChangeScreenParameters:(NSNotification *)notification;
- (void)enterNativeFullScreen;
- (void)processAfterWindowPresentedQueue;
+ (NSString *)tabBarStyleForUnified;
+ (NSString *)tabBarStyleForMetal;
@end


@interface NSWindow (NSWindowPrivate)
// Note: This hack allows us to set content shadowing separately from
// the window shadow.  This is apparently what webkit and terminal do.
- (void)_setContentHasShadow:(BOOL)shadow; // new Tiger private method

// This is a private api that makes textured windows not have rounded corners.
// We want this on Leopard.
- (void)setBottomCornerRounded:(BOOL)rounded;
@end


@interface NSWindow (NSLeopardOnly)
// Note: These functions are Leopard-only, use -[NSObject respondsToSelector:]
// before calling them to make sure everything works on Tiger too.
- (void)setAutorecalculatesContentBorderThickness:(BOOL)b forEdge:(NSRectEdge)e;
- (void)setContentBorderThickness:(CGFloat)b forEdge:(NSRectEdge)e;
@end

/**
 */
@implementation MMWindowController {
    MMVimController     *_vimController;
    MMVimView           *_vimView;
    BOOL                _setupDone;
    BOOL                _windowPresented;
    BOOL                _shouldResizeVimView;
    BOOL                _shouldKeepGUISize;
    BOOL                _shouldRestoreUserTopLeft;
    BOOL                _shouldMaximizeWindow;
    int                 _updateToolbarFlag;
    BOOL                _keepOnScreen;
    BOOL                _fullScreenEnabled;
    MMFullScreenWindow  *_fullScreenWindow;
    int                 _fullScreenOptions;
    BOOL                _delayEnterFullScreen;
    NSRect              _preFullScreenFrame;
    MMWindow            *_decoratedWindow;
    NSString            *_lastSetTitle;
    MMPoint             _userSize;
    NSPoint             _userTopLeft;
    NSPoint             _defaultTopLeft;
    BOOL                _resizingDueToMove;
    int                 _blurRadius;
    NSMutableArray      *_afterWindowPresentedQueue;
    NSSize              _desiredWindowSize;
}
@synthesize windowAutosaveKey = _windowAutosaveKey, toolbar = _toolbar, vimController = _vimController, vimView = _vimView;

- (instancetype)initWithVimController:(MMVimController *)controller
{
    unsigned styleMask =
              NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            | NSWindowStyleMaskUnifiedTitleAndToolbar
            | NSWindowStyleMaskTexturedBackground;

    if ([NSUserDefaults.standardUserDefaults boolForKey:MMNoTitleBarWindowKey]) {
        styleMask &= ~NSWindowStyleMaskTitled; // No title bar setting
    }

    // NOTE: The content rect is only used the very first time MacVim is
    // started (or rather, when ~/Library/Preferences/org.vim.MacVim.plist does
    // not exist).  The chosen values will put the window somewhere near the
    // top and in the middle of a 1024x768 screen.
    MMWindow *win = [[MMWindow alloc] initWithContentRect:NSMakeRect(242, 364, 480, 360) styleMask:styleMask backing:NSBackingStoreBuffered defer:YES];

    self = [super initWithWindow:win];
    if (!self) return nil;

    _resizingDueToMove = NO;

    _vimController = controller;
    _decoratedWindow = win;

    // Window cascading is handled by MMAppController.
    self.shouldCascadeWindows = NO;

    // NOTE: Autoresizing is enabled for the content view, but only used
    // for the tabline separator.  The vim view must be resized manually
    // because of full-screen considerations, and because its size depends
    // on whether the tabline separator is visible or not.
    win.contentView.autoresizesSubviews = YES;

    _vimView = [[MMVimView alloc] initWithFrame:win.contentView.frame vimController:_vimController];
    _vimView.autoresizingMask = NSViewNotSizable;
    [win.contentView addSubview:_vimView];
    win.delegate = self;
    win.initialFirstResponder = _vimView.textView;
    
    if (win.styleMask & NSWindowStyleMaskTexturedBackground) {
        // On Leopard, we want to have a textured window to have nice
        // looking tabs. But the textured window look implies rounded
        // corners, which looks really weird -- disable them. This is a
        // private api, though.
        if ([win respondsToSelector:@selector(setBottomCornerRounded:)])
            win.bottomCornerRounded = NO;

        // When the tab bar is toggled, it changes color for the fraction
        // of a second, probably because vim sends us events in a strange
        // order, confusing appkit's content border heuristic for a short
        // while.  This can be worked around with these two methods.  There
        // might be a better way, but it's good enough.
        if ([win respondsToSelector:@selector(setAutorecalculatesContentBorderThickness:forEdge:)])
            [win setAutorecalculatesContentBorderThickness:NO forEdge:NSMaxYEdge];
        if ([win respondsToSelector:@selector(setContentBorderThickness:forEdge:)])
            [win setContentBorderThickness:0 forEdge:NSMaxYEdge];
    }

    // Make us safe on pre-tiger OSX
    if ([win respondsToSelector:@selector(_setContentHasShadow:)])
        [win _setContentHasShadow:NO];

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    // Building on Mac OS X 10.7 or greater.

    // This puts the full-screen button in the top right of each window
    if ([win respondsToSelector:@selector(setCollectionBehavior:)])
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    // This makes windows animate when opened
    if ([win respondsToSelector:@selector(setAnimationBehavior:)])
        win.animationBehavior = NSWindowAnimationBehaviorDocumentWindow;
#endif

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationDidChangeScreenParameters:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:NSApp];

    return self;
}

- (NSString *)description
{
    NSString *format = @"%@ : setupDone=%d windowAutosaveKey=%@ vimController=%@";
    return [NSString stringWithFormat:format, self.className, _setupDone, _windowAutosaveKey, _vimController];
}

- (void)cleanup
{
    ASLogDebug(@"");

    // NOTE: Must set this before possibly leaving full-screen.
    _setupDone = NO;

    [NSNotificationCenter.defaultCenter removeObserver:self];

    if (_fullScreenEnabled) {
        // If we are closed while still in full-screen, end full-screen mode,
        // release ourselves (because this won't happen in MMWindowController)
        // and perform close operation on the original window.
        [self leaveFullScreen];
    }

    _vimController = nil;

    [_vimView removeFromSuperviewWithoutNeedingDisplay];
    [_vimView cleanup];

    // It is feasible (though unlikely) that the user quits before the window
    // controller is released, make sure the edit flag is cleared so no warning
    // dialog is displayed.
    _decoratedWindow.documentEdited = NO;

    [self.window orderOut:self];
}

- (void)openWindow
{
    // Indicates that the window is ready to be displayed, but do not display
    // (or place) it yet -- that is done in showWindow.
    //
    // TODO: Remove this method?  Everything can probably be done in
    // presentWindow: but must carefully check dependencies on 'setupDone'
    // flag.

    [self addNewTabViewItem];

    _setupDone = YES;
}

- (BOOL)presentWindow:(id)unused
{
    // If openWindow hasn't already been called then the window will be
    // displayed later.
    if (!_setupDone) return NO;

    // Place the window now.  If there are multiple screens then a choice is
    // made as to which screen the window should be on.  This means that all
    // code that is executed before this point must not depend on the screen!

    [MMAppController.shared windowControllerWillOpen:self];
    [self updateResizeConstraints];
    [self resizeWindowToFitContentSize:_vimView.desiredSize keepOnScreen:YES];

    [_decoratedWindow makeKeyAndOrderFront:self];

    // HACK! Calling makeKeyAndOrderFront: may cause Cocoa to force the window
    // into native full-screen mode (this happens e.g. if a new window is
    // opened when MacVim is already in full-screen).  In this case we don't
    // want the decorated window to pop up before the animation into
    // full-screen, so set its alpha to 0.
    if (_fullScreenEnabled && !_fullScreenWindow) _decoratedWindow.alphaValue = 0;

    _decoratedWindow.blurRadius = _blurRadius;

    // Flag that the window is now placed on screen.  From now on it is OK for
    // code to depend on the screen state.  (Such as constraining views etc.)
    _windowPresented = YES;

    // Process deferred blocks
    [self processAfterWindowPresentedQueue];

    if (_fullScreenWindow) {
        // Delayed entering of full-screen happens here (a ":set fu" in a
        // GUIEnter auto command could cause this).
        [_fullScreenWindow enterFullScreen];
        _fullScreenEnabled = YES;
    } else if (_delayEnterFullScreen) {
        // Set alpha to zero so that the decorated window doesn't pop up
        // before we enter full-screen.
        _decoratedWindow.alphaValue = 0;
        [self enterNativeFullScreen];
    }

    return YES;
}

- (void)moveWindowAcrossScreens:(NSPoint)topLeft
{
    // HACK! This method moves a window to a new origin and to a different
    // screen. This is primarily useful to avoid a scenario where such a move
    // will trigger a resize, even though the frame didn't actually change size.
    // This method should not be called unless the new origin is definitely on
    // a different screen, otherwise the next legitimate resize message will
    // be skipped.
    _resizingDueToMove = YES;
    self.window.frameTopLeftPoint = topLeft;
    _resizingDueToMove = NO;
}

- (void)updateTabsWithData:(NSData *)data
{
    [_vimView updateTabsWithData:data];
}

- (void)selectTabWithIndex:(int)index
{
    [_vimView selectTabWithIndex:index];
}

- (void)setTextDimensionsWithRows:(int)rows columns:(int)cols isLive:(BOOL)live keepGUISize:(BOOL)keepGUISize keepOnScreen:(BOOL)onScreen
{
    ASLogDebug(@"setTextDimensionsWithRows:%d columns:%d isLive:%d keepGUISize:%d keepOnScreen:%d", rows, cols, live, keepGUISize, onScreen);

    // NOTE: The only place where the (rows,columns) of the vim view are
    // modified is here and when entering/leaving full-screen.  Setting these
    // values have no immediate effect, the actual resizing of the view is done
    // in processInputQueueDidFinish.
    //
    // The 'live' flag indicates that this resize originated from a live
    // resize; it may very well happen that the view is no longer in live
    // resize when this message is received.  We refrain from changing the view
    // size when this flag is set, otherwise the window might jitter when the
    // user drags to resize the window.

    [_vimView setDesiredRows:rows columns:cols];

    if (_setupDone && !live && !keepGUISize) {
        _shouldResizeVimView = YES;
        _keepOnScreen = onScreen;
    }

    // Autosave rows and columns.
    if (_windowAutosaveKey && !_fullScreenEnabled && rows > MMMinRows && cols > MMMinColumns) {
        // HACK! If tabline is visible then window will look about one line
        // higher than it actually is so increment rows by one before
        // autosaving dimension so that the approximate total window height is
        // autosaved.  This is particularly important when window is maximized
        // vertically; if we don't add a row here a new window will appear to
        // not be tall enough when the first window is showing the tabline.
        // A negative side-effect of this is that the window will redraw on
        // startup if the window is too tall to fit on screen (which happens
        // for example if 'showtabline=2').
        // TODO: Store window pixel dimensions instead of rows/columns?
        int autosaveRows = rows;
        if (!_vimView.tabBarControl.isHidden) ++autosaveRows;

        [NSUserDefaults.standardUserDefaults setInteger:autosaveRows forKey:(NSString *)MMAutosaveRowsKey];
        [NSUserDefaults.standardUserDefaults setInteger:cols forKey:(NSString *)MMAutosaveColumnsKey];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
}

- (void)resizeView
{
    if (_setupDone) {
        _shouldResizeVimView = YES;
        _shouldKeepGUISize = YES;
    }
}

- (void)zoomWithRows:(int)rows columns:(int)cols state:(int)state
{
    [self setTextDimensionsWithRows:rows columns:cols isLive:NO keepGUISize:NO keepOnScreen:YES];

    // NOTE: If state==0 then the window should be put in the non-zoomed
    // "user state".  That is, move the window back to the last stored
    // position.  If the window is in the zoomed state, the call to change the
    // dimensions above will also reposition the window to ensure it fits on
    // the screen.  However, since resizing of the window is delayed we also
    // delay repositioning so that both happen at the same time (this avoid
    // situations where the window woud appear to "jump").
    if (!state && !NSEqualPoints(NSZeroPoint, _userTopLeft)) _shouldRestoreUserTopLeft = YES;
}

- (void)setTitle:(NSString *)title
{
    if (!title) return;

    _decoratedWindow.title = title;
    if (_fullScreenWindow) {
        _fullScreenWindow.title = title;
        // NOTE: Cocoa does not update the "Window" menu for borderless windows
        // so we have to do it manually.
        [NSApp changeWindowsItem:_fullScreenWindow title:title filename:NO];
    }
}

- (void)setDocumentFilename:(NSString *)filename
{
    if (!filename) return;

    // Ensure file really exists or the path to the proxy icon will look weird.
    // If the file does not exists, don't show a proxy icon.
    if (![NSFileManager.defaultManager fileExistsAtPath:filename]) filename = @"";

    _decoratedWindow.representedFilename = filename;
    _fullScreenWindow.representedFilename = filename;
}

- (void)setToolbar:(NSToolbar *)toolbar
{
    if (toolbar != _toolbar) {
        _toolbar = toolbar;
    }

    // NOTE: Toolbar must be set here or it won't work to show it later.
    _decoratedWindow.toolbar = _toolbar;

    // HACK! Redirect the pill button so that we can ask Vim to hide the
    // toolbar.
    NSButton *pillButton = [_decoratedWindow standardWindowButton:NSWindowToolbarButton];
    if (pillButton) {
        [pillButton setAction:@selector(toggleToolbar:)];
        [pillButton setTarget:self];
    }
}

- (void)createScrollbarWithIdentifier:(int32_t)ident type:(int)type
{
    [_vimView createScrollbarWithIdentifier:ident type:type];
}

- (BOOL)destroyScrollbarWithIdentifier:(int32_t)ident
{
    return [_vimView destroyScrollbarWithIdentifier:ident];   
}

- (BOOL)showScrollbarWithIdentifier:(int32_t)ident state:(BOOL)visible
{
    return [_vimView showScrollbarWithIdentifier:ident state:visible];
}

- (void)setScrollbarPosition:(int)pos length:(int)len identifier:(int32_t)ident
{
    [_vimView setScrollbarPosition:pos length:len identifier:ident];
}

- (void)setScrollbarThumbValue:(float)val proportion:(float)prop identifier:(int32_t)ident
{
    [_vimView setScrollbarThumbValue:val proportion:prop identifier:ident];
}

- (void)setDefaultColorsBackground:(NSColor *)back foreground:(NSColor *)fore
{
    // NOTE: This is called when the transparency changes so set the opacity
    // flag on the window here (should be faster if the window is opaque).
    const BOOL isOpaque = back.alphaComponent == 1.0f;
    _decoratedWindow.opaque = isOpaque;
    if (_fullScreenWindow) _fullScreenWindow.opaque = isOpaque;

    [_vimView setDefaultColorsBackground:back foreground:fore];
}

- (void)setFont:(NSFont *)font
{
    [NSFontManager.sharedFontManager setSelectedFont:font isMultiple:NO];
    _vimView.textView.font = font;
    [self updateResizeConstraints];
    _shouldMaximizeWindow = YES;
}

- (void)setWideFont:(NSFont *)font
{
    _vimView.textView.fontWide = font;
}

- (void)processInputQueueDidFinish
{
    // NOTE: Resizing is delayed until after all commands have been processed
    // since it often happens that more than one command will cause a resize.
    // If we were to immediately resize then the vim view size would jitter
    // (e.g.  hiding/showing scrollbars often happens several time in one
    // update).
    // Also delay toggling the toolbar until after scrollbars otherwise
    // problems arise when showing toolbar and scrollbar at the same time, i.e.
    // on "set go+=rT".

    // Update toolbar before resizing, since showing the toolbar may require
    // the view size to become smaller.
    if (_updateToolbarFlag != 0)
        [self updateToolbar];

    // NOTE: If the window has not been presented then we must avoid resizing
    // the views since it will cause them to be constrained to the screen which
    // has not yet been set!
    if (_windowPresented && _shouldResizeVimView) {
        _shouldResizeVimView = NO;

        // Make sure full-screen window stays maximized (e.g. when scrollbar or
        // tabline is hidden) according to 'fuopt'.

        BOOL didMaximize = NO;
        if (_shouldMaximizeWindow && _fullScreenEnabled &&
           (_fullScreenOptions & (FUOPT_MAXVERT|FUOPT_MAXHORZ)) != 0)
            didMaximize = [self maximizeWindow:_fullScreenOptions];

        _shouldMaximizeWindow = NO;

        // Resize Vim view and window, but don't do this now if the window was
        // just reszied because this would make the window "jump" unpleasantly.
        // Instead wait for Vim to respond to the resize message and do the
        // resizing then.
        // TODO: What if the resize message fails to make it back?
        if (!didMaximize) {
            NSSize originalSize = _vimView.frame.size;
            int rows = 0, cols = 0;
            const NSSize contentSize = [_vimView constrainRows:&rows columns:&cols toSize:
                                  _fullScreenWindow ? _fullScreenWindow.frame.size :
                                  _fullScreenEnabled ? _desiredWindowSize :
                                  [self constrainContentSizeToScreenSize:_vimView.desiredSize]];

            // Setting 'guioptions+=k' will make shouldKeepGUISize true, which
            // means avoid resizing the window. Instead, resize the view instead
            // to keep the GUI window's size consistent.
            const bool avoidWindowResize = _shouldKeepGUISize && !_fullScreenEnabled;

            if (!avoidWindowResize) {
                _vimView.frameSize = contentSize;
            }
            else {
                [_vimView setFrameSizeKeepGUISize:originalSize];
            }

            if (_fullScreenWindow) {
                // NOTE! Don't mark the full-screen content view as needing an
                // update unless absolutely necessary since when it is updated
                // the entire screen is cleared.  This may cause some parts of
                // the Vim view to be cleared but not redrawn since Vim does
                // not realize that we've erased part of the view.
                if (!NSEqualSizes(originalSize, contentSize)) {
                    _fullScreenWindow.contentView.needsDisplay = YES;
                    [_fullScreenWindow centerView];
                }
            } else {
                if (!avoidWindowResize) {
                    [self resizeWindowToFitContentSize:contentSize keepOnScreen:_keepOnScreen];
                }
            }
        }

        _keepOnScreen = NO;
        _shouldKeepGUISize = NO;
    }
}

- (void)showTabBar:(BOOL)on
{
    _vimView.tabBarControl.hidden = !on;
    [self updateTablineSeparator];
    _shouldMaximizeWindow = YES;
}

- (void)showToolbar:(BOOL)on size:(int)size mode:(int)mode
{
    if (!_toolbar) return;

    _toolbar.sizeMode = size;
    _toolbar.displayMode = mode;

    // Positive flag shows toolbar, negative hides it.
    _updateToolbarFlag = on ? 1 : -1;

    // NOTE: If the window is not visible we must toggle the toolbar
    // immediately, otherwise "set go-=T" in .gvimrc will lead to the toolbar
    // showing its hide animation every time a new window is opened.  (See
    // processInputQueueDidFinish for the reason why we need to delay toggling
    // the toolbar when the window is visible.)
    //
    // Also, the delayed updateToolbar will have the correct shouldKeepGUISize
    // set when it's called, which is important for that function to respect
    // guioptions 'k'.
}

- (void)setMouseShape:(int)shape
{
    _vimView.textView.mouseShape = shape;
}

- (void)adjustLinespace:(int)linespace
{
    if (_vimView.textView) {
        _vimView.textView.linespace = (float)linespace;
    }
}

- (void)adjustColumnspace:(int)columnspace
{
    if (_vimView.textView) {
        _vimView.textView.columnspace = (float)columnspace;
    }
}

- (void)liveResizeWillStart
{
    if (!_setupDone) return;

    // Save the original title, if we haven't already.
    if (!_lastSetTitle) {
        _lastSetTitle = _decoratedWindow.title;
    }

    // NOTE: During live resize Cocoa goes into "event tracking mode".  We have
    // to add the backend connection to this mode in order for resize messages
    // from Vim to reach MacVim.  We do not wish to always listen to requests
    // in event tracking mode since then MacVim could receive DO messages at
    // unexpected times (e.g. when a key equivalent is pressed and the menu bar
    // momentarily lights up).
    id proxy = _vimController.backendProxy;
    NSConnection *connection = [(NSDistantObject*)proxy connectionForProxy];
    [connection addRequestMode:NSEventTrackingRunLoopMode];
}

- (void)liveResizeDidEnd
{
    if (!_setupDone) return;

    // See comment above regarding event tracking mode.
    id proxy = _vimController.backendProxy;
    NSConnection *connection = [(NSDistantObject *)proxy connectionForProxy];
    [connection removeRequestMode:NSEventTrackingRunLoopMode];

    // If we saved the original title while resizing, restore it.
    if (_lastSetTitle) {
        _decoratedWindow.title = _lastSetTitle;
        _lastSetTitle = nil;
    }
}

- (void)setBlurRadius:(int)radius
{
    _blurRadius = radius;
    if (_windowPresented) { 
        _decoratedWindow.blurRadius = radius;
    }
}

- (void)enterFullScreen:(int)fuoptions backgroundColor:(NSColor *)back
{
    if (_fullScreenEnabled) return;

    BOOL useNativeFullScreen = [NSUserDefaults.standardUserDefaults boolForKey:MMNativeFullScreenKey];
    // Make sure user is not trying to use native full-screen on systems that
    // do not support it.
    if (![NSWindow instancesRespondToSelector:@selector(toggleFullScreen:)])
        useNativeFullScreen = NO;

    _fullScreenOptions = fuoptions;
    if (useNativeFullScreen) {
        // Enter native full-screen mode.  Only supported on Mac OS X 10.7+.
        if (_windowPresented) {
            [self enterNativeFullScreen];
        } else {
            _delayEnterFullScreen = YES;
        }
    } else {
        // Enter custom full-screen mode.  Always supported.
        ASLogInfo(@"Enter custom full-screen");

        // _fullScreenWindow could be non-nil here if this is called multiple
        // times during startup.
 
        _fullScreenWindow = [[MMFullScreenWindow alloc] initWithWindow:_decoratedWindow view:_vimView backgroundColor:back];
        _fullScreenWindow.options = fuoptions;
        _fullScreenWindow.representedFilename = _decoratedWindow.representedFilename;

        // NOTE: Do not enter full-screen until the window has been presented
        // since we don't actually know which screen to use before then.  (The
        // custom full-screen can appear on any screen, as opposed to native
        // full-screen which always uses the main screen.)
        if (_windowPresented) {
            [_fullScreenWindow enterFullScreen];
            _fullScreenEnabled = YES;

            // The resize handle disappears so the vim view needs to update the
            // scrollbars.
            _shouldResizeVimView = YES;
        }
    }
}

- (void)leaveFullScreen
{
    if (!_fullScreenEnabled) return;

    ASLogInfo(@"Exit full-screen");

    _fullScreenEnabled = NO;
    if (_fullScreenWindow) {
        // Using custom full-screen
        [_fullScreenWindow leaveFullScreen];
        _fullScreenWindow = nil;

        // The vim view may be too large to fit the screen, so update it.
        _shouldResizeVimView = YES;
    } else {
        // Using native full-screen
        // NOTE: fullScreenEnabled is used to detect if we enter full-screen
        // programatically and so must be set before calling
        // realToggleFullScreen:.
        NSParameterAssert(_fullScreenEnabled == NO);
        [_decoratedWindow realToggleFullScreen:self];
    }
}

- (void)setFullScreenBackgroundColor:(NSColor *)back
{
    if (_fullScreenWindow) _fullScreenWindow.backgroundColor = back;
}

- (void)invFullScreen:(id)sender
{
    [_vimController addVimInput:@"<C-\\><C-N>:set invfu<CR>"];
}

- (void)setBufferModified:(BOOL)modified
{
    // NOTE: We only set the document edited flag on the decorated window since
    // the custom full-screen window has no close button anyway.  (It also
    // saves us from keeping track of the flag in two different places.)
    _decoratedWindow.documentEdited = modified;
}

- (void)setTopLeft:(NSPoint)pt
{
    if (_setupDone) {
        _decoratedWindow.frameTopLeftPoint = pt;
    } else {
        // Window has not been "opened" yet (see openWindow:) but remember this
        // value to be used when the window opens.
        _defaultTopLeft = pt;
    }
}

- (BOOL)getDefaultTopLeft:(NSPoint*)pt
{
    // A default top left point may be set in .[g]vimrc with the :winpos
    // command.  (If this has not been done the top left point will be the zero
    // point.)
    if (pt && !NSEqualPoints(_defaultTopLeft, NSZeroPoint)) {
        *pt = _defaultTopLeft;
        return YES;
    }
    return NO;
}

- (IBAction)addNewTab:(id)sender
{
    [_vimView addNewTab:sender];
}

- (IBAction)toggleToolbar:(id)sender
{
    [_vimController sendMessage:ToggleToolbarMsgID data:nil];
}

- (IBAction)performClose:(id)sender
{
    // NOTE: With the introduction of :macmenu it is possible to bind
    // File.Close to ":conf q" but at the same time have it send off the
    // performClose: action.  For this reason we no longer need the CloseMsgID
    // message.  However, we still need File.Close to send performClose:
    // otherwise Cmd-w will not work on dialogs.
    [self vimMenuItemAction:sender];
}

- (IBAction)findNext:(id)sender
{
    [self doFindNext:YES];
}

- (IBAction)findPrevious:(id)sender
{
    [self doFindNext:NO];
}

- (IBAction)vimMenuItemAction:(NSMenuItem *)item
{
    if (![item isKindOfClass:NSMenuItem.class]) return;

    // TODO: Make into category on NSMenuItem which returns descriptor.
    NSMutableArray *desc = @[item.title].mutableCopy;
    for (NSMenu *menu = item.menu; menu; menu = menu.supermenu)
        [desc insertObject:menu.title atIndex:0];

    // The "MainMenu" item is part of the Cocoa menu and should not be part of
    // the descriptor.
    if ([desc.firstObject isEqual:@"MainMenu"])
        [desc removeObjectAtIndex:0];

    NSDictionary *attrs = @{@"descriptor": desc};
    [_vimController sendMessage:ExecuteMenuMsgID data:attrs.dictionaryAsData];
}

- (IBAction)vimToolbarItemAction:(id)sender
{
    NSDictionary *attrs = @{@"descriptor": @[@"ToolBar", [sender label]]};
    [_vimController sendMessage:ExecuteMenuMsgID data:attrs.dictionaryAsData];
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
- (IBAction)vimTouchbarItemAction:(id)sender
{
    NSDictionary *attrs = @{@"descriptor": @[@"TouchBar", [sender label]]};
    [_vimController sendMessage:ExecuteMenuMsgID data:attrs.dictionaryAsData];
}
#endif

- (IBAction)fontSizeUp:(id)sender
{
    [NSFontManager.sharedFontManager modifyFont:@(NSSizeUpFontAction)];
}

- (IBAction)fontSizeDown:(id)sender
{
    [NSFontManager.sharedFontManager modifyFont:@(NSSizeDownFontAction)];
}

- (IBAction)findAndReplace:(id)sender
{
    MMFindReplaceController *controller = MMFindReplaceController.shared;
    int flags = 0;

    // NOTE: The 'flags' values must match the FRD_ defines in gui.h (except
    // for 0x100 which we use to indicate a backward search).
    switch ([sender tag]) {
        case 1: flags = 0x100; break;
        case 2: flags = 3; break;
        case 3: flags = 4; break;
    }

    if (controller.matchWord) flags |= 0x08;
    if (!controller.ignoreCase) flags |= 0x10;

    NSDictionary *args = @{@"find": controller.findString, @"replace": controller.replaceString, @"flags" : @(flags)};
    [_vimController sendMessage:FindReplaceMsgID data:args.dictionaryAsData];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(vimMenuItemAction:) || item.action == @selector(performClose:))
        return item.tag;
    return YES;
}

// -- NSWindow delegate ------------------------------------------------------

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    MMAppController.shared.mainMenu = _vimController.mainMenu;
    if (_vimView.textView) {
        [NSFontManager.sharedFontManager setSelectedFont:_vimView.textView.font isMultiple:NO];
    }
}

- (void)windowDidBecomeKey:(NSNotificationCenter *)notification
{
    [_vimController sendMessage:GotFocusMsgID data:nil];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    [_vimController sendMessage:LostFocusMsgID data:nil];
}

- (BOOL)windowShouldClose:(id)sender
{
    // Don't close the window now; Instead let Vim decide whether to close the
    // window or not.
    [_vimController sendMessage:VimShouldCloseMsgID data:nil];
    return NO;
}

- (void)windowDidMove:(NSNotification *)notification
{
    if (!_setupDone)
        return;

    if (_fullScreenEnabled) {
        // NOTE: The full-screen is not supposed to be able to be moved.  If we
        // do get here while in full-screen something unexpected happened (e.g.
        // the full-screen window was on an external display that got
        // unplugged).
        return;
    }

    const NSRect frame = _decoratedWindow.frame;
    const NSPoint topLeft = {frame.origin.x, NSMaxY(frame)};
    if (_windowAutosaveKey) {
        NSString *topLeftString = NSStringFromPoint(topLeft);
        [NSUserDefaults.standardUserDefaults setObject:topLeftString forKey:_windowAutosaveKey];
    }

    // NOTE: This method is called when the user drags the window, but not when
    // the top left point changes programmatically.
    // NOTE 2: Vim counts Y-coordinates from the top of the screen.
    const int pos[2] = {(int)topLeft.x, (int)(NSMaxY(_decoratedWindow.screen.frame) - topLeft.y)};
    NSData *data = [NSData dataWithBytes:pos length:2 * sizeof(int)];
    [_vimController sendMessage:SetWindowPositionMsgID data:data];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
    _desiredWindowSize = frameSize;
    return frameSize;
}

- (void)windowDidResize:(id)sender
{
    if (_resizingDueToMove) {
        _resizingDueToMove = NO;
        return;
    }

    if (!_setupDone)
        return;

    // NOTE: We need to update the window frame size for Split View even though
    // in full-screen on El Capitan or later.
    if (floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max && _fullScreenEnabled)
        return;

    // NOTE: Since we have no control over when the window may resize (Cocoa
    // may resize automatically) we simply set the view to fill the entire
    // window.  The vim view takes care of notifying Vim if the number of
    // (rows,columns) changed.
    if (_shouldKeepGUISize) {
        // This happens when code manually call setFrame: when we are performing
        // an operation that wants to preserve GUI size (e.g. in updateToolbar:).
        // Respect the wish, and pass that along.
        [_vimView setFrameSizeKeepGUISize:self.contentSize];
    }
    else {
        _vimView.frameSize = self.contentSize;
    }
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification
{
    [_vimController sendMessage:BackingPropertiesChangedMsgID data:nil];
}

// This is not an NSWindow delegate method, our custom MMWindow class calls it
// instead of the usual windowWillUseStandardFrame:defaultFrame:.
- (IBAction)zoom:(id)sender
{
    NSScreen *screen = _decoratedWindow.screen;
    if (!screen) {
        ASLogNotice(@"Window not on screen, zoom to main screen");
        screen = NSScreen.mainScreen;
        if (!screen) {
            ASLogNotice(@"No main screen, abort zoom");
            return;
        }
    }

    // Decide whether too zoom horizontally or not (always zoom vertically).
    NSEvent *event = NSApp.currentEvent;
    const BOOL cmdLeftClick = event.type == NSEventTypeLeftMouseUp && event.modifierFlags & NSEventModifierFlagCommand;
    BOOL zoomBoth = [NSUserDefaults.standardUserDefaults boolForKey:MMZoomBothKey];
    zoomBoth = (zoomBoth && !cmdLeftClick) || (!zoomBoth && cmdLeftClick);

    // Figure out how many rows/columns can fit while zoomed.
    int rowsZoomed, colsZoomed;
    NSRect maxFrame = screen.visibleFrame;
    NSRect contentRect = [_decoratedWindow contentRectForFrameRect:maxFrame];
    [_vimView constrainRows:&rowsZoomed columns:&colsZoomed toSize:contentRect.size];

    const MMPoint currentSize = _vimView.textView.maxSize;

    int rows, cols;
    const BOOL isZoomed = zoomBoth ? currentSize.row >= rowsZoomed && currentSize.col >= colsZoomed : currentSize.row >= rowsZoomed;
    if (isZoomed) {
        rows = _userSize.row > 0 ? _userSize.row : currentSize.row;
        cols = _userSize.col > 0 ? _userSize.col : currentSize.col;
    } else {
        rows = rowsZoomed;
        cols = zoomBoth ? colsZoomed : currentSize.col;
        if (currentSize.row + 2 < rows || currentSize.col + 2 < cols) {
            // The window is being zoomed so save the current "user state".
            // Note that if the window does not enlarge by a 'significant'
            // number of rows/columns then we don't save the current state.
            // This is done to take into account toolbar/scrollbars
            // showing/hiding.
            _userSize = currentSize;
            NSRect frame = _decoratedWindow.frame;
            _userTopLeft = NSMakePoint(frame.origin.x, NSMaxY(frame));
        }
    }

    // NOTE: Instead of resizing the window immediately we send a zoom message
    // to the backend so that it gets a chance to resize before the window
    // does.  This avoids problems with the window flickering when zooming.
    const int info[3] = {rows, cols, !isZoomed};
    NSData *data = [NSData dataWithBytes:info length:3 * sizeof(int)];
    [_vimController sendMessage:ZoomMsgID data:data];
}

// -- Services menu delegate -------------------------------------------------

- (id)validRequestorForSendType:(NSString *)sendType returnType:(NSString *)returnType
{
    if ([sendType isEqual:NSStringPboardType] && [self askBackendForStarRegister:nil]) return self;
    return [super validRequestorForSendType:sendType returnType:returnType];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard types:(NSArray *)types
{
    if (![types containsObject:NSStringPboardType]) return NO;
    return [self askBackendForStarRegister:pboard];
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
    // Replace the current selection with the text on the pasteboard.
    NSArray *types = pboard.types;
    if ([types containsObject:NSStringPboardType]) {
        NSString *input = [NSString stringWithFormat:@"s%@", [pboard stringForType:NSStringPboardType]];
        [_vimController addVimInput:input];
        return YES;
    }
    return NO;
}

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)

// -- Full-screen delegate ---------------------------------------------------

- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)opt
{
    return opt | NSApplicationPresentationAutoHideToolbar;
}

- (NSArray *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window
{
    return @[_decoratedWindow];
}

- (void)window:(NSWindow *)window startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration
{
    // Fade out window, remove title bar and maximize, then fade back in.
    // (There is a small delay before window is maximized but usually this is
    // not noticeable on a relatively modern Mac.)

    // Fade out
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5 * duration;
        window.animator.alphaValue = 0;
    } completionHandler:^{
        [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullScreen)];
        NSString *tabBarStyle = [[self class] tabBarStyleForUnified];
        [[_vimView tabBarControl] setStyleNamed:tabBarStyle];
        [self updateTablineSeparator];

        // Stay dark for some time to wait for things to sync, then do the full screen operation
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.5 * duration;
            window.animator.alphaValue = 0;
        } completionHandler:^{
            [self maximizeWindow:_fullScreenOptions];
            
            // Fade in
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.5 * duration;
                window.animator.alphaValue = 1;
            } completionHandler:^{
                // Do nothing
            }];
        }];
    }];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    // Store window frame and use it when exiting full-screen.
    _preFullScreenFrame = _decoratedWindow.frame;

    // The separator should never be visible in fullscreen or split-screen.
    [_decoratedWindow hideTablineSeparator:YES];
  
    // ASSUMPTION: fullScreenEnabled always reflects the state of Vim's 'fu'.
    if (!_fullScreenEnabled) {
        ASLogDebug(@"Full-screen out of sync, tell Vim to set 'fu'");
        // NOTE: If we get here it means that Cocoa has somehow entered
        // full-screen without us getting to set the 'fu' option first, so Vim
        // and the GUI are out of sync.  The following code (eventually) gets
        // them back into sync.  A problem is that the full-screen options have
        // not been set, so we have to cache that state and grab it here.
        _fullScreenOptions = [[_vimController objectForVimStateKey:@"fullScreenOptions"] intValue];
        _fullScreenEnabled = YES;
        [self invFullScreen:self];
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_10_Max) {
        // NOTE: On El Capitan, we need to redraw the view when entering
        // full-screen using :fullscreen option (including Ctrl-Cmd-f).
        [_vimController sendMessage:BackingPropertiesChangedMsgID data:nil];
    }
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window
{
    // NOTE: This message can be called without
    // window:startCustomAnimationToEnterFullScreenWithDuration: ever having
    // been called so any state to store before entering full-screen must be
    // stored in windowWillEnterFullScreen: which always gets called.
    ASLogNotice(@"Failed to ENTER full-screen, restoring window frame...");

    _fullScreenEnabled = NO;
    window.alphaValue = 1;
    window.styleMask = (window.styleMask & ~NSWindowStyleMaskFullScreen);
    _vimView.tabBarControl.styleNamed = self.class.tabBarStyleForMetal;
    [self updateTablineSeparator];
    [window setFrame:_preFullScreenFrame display:YES];
}

- (NSArray *)customWindowsToExitFullScreenForWindow:(NSWindow *)window
{
    return @[_decoratedWindow];
}

- (void)window:(NSWindow *)window startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration
{
    if (!_setupDone) {
        // HACK! The window has closed but Cocoa still brings it back to life
        // and shows a grey box the size of the window unless we explicitly
        // hide it by setting its alpha to 0 here.
        window.alphaValue = 0;
        return;
    }

    // Fade out window, add back title bar and restore window frame, then fade
    // back in.  (There is a small delay before window contents is drawn after
    // the window frame is set but usually this is not noticeable on a
    // relatively modern Mac.)
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5 * duration;
        window.animator.alphaValue = 0;
    } completionHandler:^{
        window.styleMask = (window.styleMask & ~NSWindowStyleMaskFullScreen);
        _vimView.tabBarControl.styleNamed = self.class.tabBarStyleForMetal; 
        [self updateTablineSeparator];
        [window setFrame:_preFullScreenFrame display:YES];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.5 * duration;
            window.animator.alphaValue = 1;
        } completionHandler:^{
            // Do nothing
        }];
    }];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    // ASSUMPTION: fullScreenEnabled always reflects the state of Vim's 'fu'.
    if (_fullScreenEnabled) {
        ASLogDebug(@"Full-screen out of sync, tell Vim to clear 'fu'");
        // NOTE: If we get here it means that Cocoa has somehow exited
        // full-screen without us getting to clear the 'fu' option first, so
        // Vim and the GUI are out of sync.  The following code (eventually)
        // gets them back into sync.
        _fullScreenEnabled = NO;
        [self invFullScreen:self];
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_10_Max) {
        // NOTE: On El Capitan, we need to redraw the view when leaving
        // full-screen by moving the window out from Split View.
        [_vimController sendMessage:BackingPropertiesChangedMsgID data:nil];
    }
    [self updateTablineSeparator];
}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window
{
    // TODO: Is this the correct way to deal with this message?  Are we still
    // in full-screen at this point?
    ASLogNotice(@"Failed to EXIT full-screen, maximizing window...");

    _fullScreenEnabled = YES;
    window.alphaValue = 1;
    window.styleMask = window.styleMask | NSWindowStyleMaskFullScreen;
    _vimView.tabBarControl.styleNamed = self.class.tabBarStyleForUnified;
    [self updateTablineSeparator];
    [self maximizeWindow:_fullScreenOptions];
}

#endif // (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)

- (void)runAfterWindowPresentedUsingBlock:(void (^)(void))block
{
    if (_windowPresented) { // no need to defer block, just run it now
        block();
        return;
    }

    // run block later
    if (!_afterWindowPresentedQueue) _afterWindowPresentedQueue = NSMutableArray.new;
    [_afterWindowPresentedQueue addObject:[block copy]];
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
- (NSTouchBar *)makeTouchBar
{
    return [_vimController makeTouchBar];
}
#endif

@end // MMWindowController

/**
 */
@implementation MMWindowController (Private)

- (NSSize)contentSize
{
    // NOTE: Never query the content view directly for its size since it may
    // not return the same size as contentRectForFrameRect: (e.g. when in
    // windowed mode and the tabline separator is visible)!
    return [self.window contentRectForFrameRect:self.window.frame].size;
}

- (void)resizeWindowToFitContentSize:(NSSize)contentSize keepOnScreen:(BOOL)onScreen
{
    NSRect frame = _decoratedWindow.frame;
    NSRect contentRect = [_decoratedWindow contentRectForFrameRect:frame];

    // Keep top-left corner of the window fixed when resizing.
    contentRect.origin.y -= contentSize.height - contentRect.size.height;
    contentRect.size = contentSize;

    NSRect newFrame = [_decoratedWindow frameRectForContentRect:contentRect];

    if (_shouldRestoreUserTopLeft) {
        // Restore user top left window position (which is saved when zooming).
        CGFloat dy = _userTopLeft.y - NSMaxY(newFrame);
        newFrame.origin.x = _userTopLeft.x;
        newFrame.origin.y += dy;
        _shouldRestoreUserTopLeft = NO;
    }

    NSScreen *screen = _decoratedWindow.screen;
    if (onScreen && screen) {
        // Ensure that the window fits inside the visible part of the screen.
        // If there are more than one screen the window will be moved to fit
        // entirely in the screen that most of it occupies.
        NSRect maxFrame = _fullScreenEnabled ? screen.frame : screen.visibleFrame;
        maxFrame = [self constrainFrame:maxFrame];

        if (newFrame.size.width > maxFrame.size.width) {
            newFrame.size.width = maxFrame.size.width;
            newFrame.origin.x = maxFrame.origin.x;
        }
        if (newFrame.size.height > maxFrame.size.height) {
            newFrame.size.height = maxFrame.size.height;
            newFrame.origin.y = maxFrame.origin.y;
        }

        if (newFrame.origin.y < maxFrame.origin.y)
            newFrame.origin.y = maxFrame.origin.y;
        if (NSMaxY(newFrame) > NSMaxY(maxFrame))
            newFrame.origin.y = NSMaxY(maxFrame) - newFrame.size.height;
        if (newFrame.origin.x < maxFrame.origin.x)
            newFrame.origin.x = maxFrame.origin.x;
        if (NSMaxX(newFrame) > NSMaxX(maxFrame))
            newFrame.origin.x = NSMaxX(maxFrame) - newFrame.size.width;
    }

    if (_fullScreenEnabled && screen) {
        // Keep window centered when in native full-screen.
        NSRect screenFrame = screen.frame;
        newFrame.origin.y = screenFrame.origin.y + round(0.5*(screenFrame.size.height - newFrame.size.height));
        newFrame.origin.x = screenFrame.origin.x + round(0.5*(screenFrame.size.width - newFrame.size.width));
    }

    ASLogDebug(@"Set window frame: %@", NSStringFromRect(newFrame));
    [_decoratedWindow setFrame:newFrame display:YES];

    const NSPoint oldTopLeft = {frame.origin.x, NSMaxY(frame)};
    const NSPoint newTopLeft = {newFrame.origin.x, NSMaxY(newFrame)};
    if (!NSEqualPoints(oldTopLeft, newTopLeft)) {
        // NOTE: The window top left position may change due to the window
        // being moved e.g. when the tabline is shown so we must tell Vim what
        // the new window position is here.
        // NOTE 2: Vim measures Y-coordinates from top of screen.
        int pos[2] = {(int)newTopLeft.x, (int)(NSMaxY(_decoratedWindow.screen.frame) - newTopLeft.y)};
        NSData *data = [NSData dataWithBytes:pos length:2 * sizeof(int)];
        [_vimController sendMessage:SetWindowPositionMsgID data:data];
    }
}

- (NSSize)constrainContentSizeToScreenSize:(NSSize)contentSize
{
    NSWindow *win = self.window;
    if (!win.screen) return contentSize;

    // NOTE: This may be called in both windowed and full-screen mode.  The
    // "visibleFrame" method does not overlap menu and dock so should not be
    // used in full-screen.
    NSRect screenRect = _fullScreenEnabled ? win.screen.frame : win.screen.visibleFrame;
    NSRect rect = [win contentRectForFrameRect:screenRect];

    if (contentSize.height > rect.size.height) contentSize.height = rect.size.height;
    if (contentSize.width > rect.size.width) contentSize.width = rect.size.width;

    return contentSize;
}

- (NSRect)constrainFrame:(NSRect)frame
{
    // Constrain the given (window) frame so that it fits an even number of
    // rows and columns.
    NSRect contentRect = [_decoratedWindow contentRectForFrameRect:frame];
    NSSize constrainedSize = [_vimView constrainRows:NULL columns:NULL toSize:contentRect.size];

    contentRect.origin.y += contentRect.size.height - constrainedSize.height;
    contentRect.size = constrainedSize;

    return [_decoratedWindow frameRectForContentRect:contentRect];
}

- (void)updateResizeConstraints
{
    if (!_setupDone) return;

    // Set the resize increments to exactly match the font size; this way the
    // window will always hold an integer number of (rows,columns).
    [_decoratedWindow setContentResizeIncrements:_vimView.textView.cellSize];
    [_decoratedWindow setContentMinSize:_vimView.minSize];
}

- (NSTabViewItem *)addNewTabViewItem
{
    return [_vimView addNewTabViewItem];
}

- (BOOL)askBackendForStarRegister:(NSPasteboard *)pb
{ 
    // TODO: Can this be done with evaluateExpression: instead?
    BOOL reply = NO;
    id backendProxy = _vimController.backendProxy;

    if (backendProxy) {
        @try {
            reply = [backendProxy starRegisterToPasteboard:pb];
        } @catch (NSException *e) {
            ASLogDebug(@"starRegisterToPasteboard: failed: pid=%d reason=%@", _vimController.pid, e);
        }
    }

    return reply;
}

- (void)updateTablineSeparator
{
    BOOL tabBarVisible  = !_vimView.tabBarControl.isHidden;
    BOOL toolbarHidden  = _decoratedWindow.toolbar == nil;
    BOOL windowTextured = (_decoratedWindow.styleMask & NSWindowStyleMaskTexturedBackground) != 0;
    BOOL hideSeparator  = NO;

    if (_fullScreenEnabled || tabBarVisible)
        hideSeparator = YES;
    else
        hideSeparator = toolbarHidden && !windowTextured;

    [self hideTablineSeparator:hideSeparator];
}

- (void)hideTablineSeparator:(BOOL)hide
{
    // The full-screen window has no tabline separator so we operate on
    // _decoratedWindow instead of [self window].
    if ([_decoratedWindow hideTablineSeparator:hide]) {
        // The tabline separator was toggled so the content view must change
        // size.
        [self updateResizeConstraints];
    }
}

- (void)doFindNext:(BOOL)next
{
    NSString *query = nil;
#if 0
    // Use current query if the search field is selected.
    id searchField = [[self searchFieldItem] view];
    if (searchField && [[searchField stringValue] length] > 0 && [_decoratedWindow firstResponder] == [searchField currentEditor])
        query = [searchField stringValue];
#endif

    if (!query) {
        // Use find pasteboard for next query.
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSFindPboard];
        NSString *bestType = [pb availableTypeFromArray:@[VimFindPboardType, NSStringPboardType]];

        // See gui_macvim_add_to_find_pboard() for an explanation of these
        // types.
        if ([bestType isEqual:VimFindPboardType]) {
            query = [pb stringForType:VimFindPboardType];
        } else {
            const BOOL shareFindPboard = [NSUserDefaults.standardUserDefaults boolForKey:MMShareFindPboardKey];
            if (shareFindPboard) {
                query = [pb stringForType:NSStringPboardType];
            }
        }
    }

    NSString *input = nil;
    if (query) {
        // NOTE: The '/' register holds the last search string.  By setting it
        // (using the '@/' syntax) we fool Vim into thinking that it has
        // already searched for that string and then we can simply use 'n' or
        // 'N' to find the next/previous match.
        input = [NSString stringWithFormat:@"<C-\\><C-N>:let @/='%@'<CR>%c", query, next ? 'n' : 'N'];
    } else {
        input = next ? @"<C-\\><C-N>n" : @"<C-\\><C-N>N"; 
    }

    [_vimController addVimInput:input];
}

- (void)updateToolbar
{
    if (!_toolbar || 0 == _updateToolbarFlag) return;

    // Positive flag shows toolbar, negative hides it.
    const BOOL on = _updateToolbarFlag > 0;

    const NSRect origWindowFrame = _decoratedWindow.frame;
    const BOOL origHasToolbar = _decoratedWindow.toolbar != nil;

    _decoratedWindow.toolbar = on ? _toolbar : nil;

    if (_shouldKeepGUISize && !_fullScreenEnabled && origHasToolbar != on) {
        // "shouldKeepGUISize" means guioptions has 'k' in it, indicating that user doesn't
        // want the window to resize itself. In non-fullscreen when we call setToolbar:
        // Cocoa automatically resizes the window so we need to un-resize it back to
        // original.

        const NSRect newWindowFrame = _decoratedWindow.frame;
        if (newWindowFrame.size.height == origWindowFrame.size.height) {
            // This is an odd case here, where the window has not changed size at all.
            // The addition/removal of toolbar should have changed its size. This means that
            // there isn't enough space to grow the window on the screen. Usually we rely
            // on windowDidResize: to call setFrameSizeKeepGUISize for us but now we have
            // to do it manually in this special case.
            [_vimView setFrameSizeKeepGUISize:self.contentSize];
        }
        else {
            [_decoratedWindow setFrame:origWindowFrame display:YES];
        }
    }

    [self updateTablineSeparator];

    _updateToolbarFlag = 0;
}

- (BOOL)maximizeWindow:(int)options
{
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_10_Max) {
        // NOTE: Prevent to resize the window in Split View on El Capitan or
        // later.
        return NO;
    }

    const MMPoint currentSize = _vimView.textView.maxSize;

    // NOTE: Do not use [NSScreen visibleFrame] when determining the screen
    // size since it compensates for menu and dock.
    int maxRows, maxColumns;
    NSScreen *screen = _decoratedWindow.screen;
    if (!screen) {
        ASLogNotice(@"Window not on screen, using main screen");
        screen = NSScreen.mainScreen;
    }
    [_vimView constrainRows:&maxRows columns:&maxColumns toSize:screen.frame.size];

    ASLogDebug(@"Window dimensions max: %dx%d  current: %dx%d", maxRows, maxColumns, currentSize.row, currentSize.col);

    // Compute current fu size
    MMPoint fullscreenSize = currentSize;
    if (options & FUOPT_MAXVERT) fullscreenSize.row = maxRows;
    if (options & FUOPT_MAXHORZ) fullscreenSize.col = maxColumns;

    // If necessary, resize vim to target fu size
    if (!MMPointIsEqual(fullscreenSize, currentSize)) {
        // The size sent here is queued and sent to vim when it's in
        // event processing mode again. Make sure to only send the values we
        // care about, as they override any changes that were made to 'lines'
        // and 'columns' after 'fu' was set but before the event loop is run.
        NSData *data = nil;
        int msgid = 0;
        if (currentSize.row != fullscreenSize.row && currentSize.col != fullscreenSize.col) {
            const int newSize[] = {fullscreenSize.row, fullscreenSize.col};
            data = [NSData dataWithBytes:newSize length:sizeof(newSize)];
            msgid = SetTextDimensionsMsgID;
        } else if (currentSize.row != fullscreenSize.row) {
            data = [NSData dataWithBytes:&fullscreenSize.row length:sizeof(int)];
            msgid = SetTextRowsMsgID;
        } else if (currentSize.col != fullscreenSize.col) {
            data = [NSData dataWithBytes:&fullscreenSize.col length:sizeof(int)];
            msgid = SetTextColumnsMsgID;
        }
        NSParameterAssert(data && msgid != 0);

        ASLogDebug(@"%s: %dx%d", MessageStrings[msgid], fullscreenSize.row, fullscreenSize.col);
        [_vimController sendMessage:msgid data:data];
        _vimView.textView.maxSize = fullscreenSize;

        // Indicate that window was resized
        return YES;
    }

    // Indicate that window was not resized
    return NO;
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
    if (_fullScreenWindow) {
        [_fullScreenWindow applicationDidChangeScreenParameters:notification];
    } else if (_fullScreenEnabled) {
        ASLogDebug(@"Re-maximizing full-screen window...");
        [self maximizeWindow:_fullScreenOptions];
    }
}

- (void)enterNativeFullScreen
{
    if (_fullScreenEnabled) return;

    ASLogInfo(@"Enter native full-screen");

    _fullScreenEnabled = YES;

    // NOTE: fullScreenEnabled is used to detect if we enter full-screen
    // programatically and so must be set before calling realToggleFullScreen:.
    NSParameterAssert(_fullScreenEnabled == YES);
    [_decoratedWindow realToggleFullScreen:self];
}

- (void)processAfterWindowPresentedQueue
{
    for (void (^block)(void) in _afterWindowPresentedQueue) block();
    _afterWindowPresentedQueue = nil;
}

+ (NSString *)tabBarStyleForUnified
{
    return shouldUseYosemiteTabBarStyle() ? @"Yosemite" : @"Unified";
}

+ (NSString *)tabBarStyleForMetal
{
    return shouldUseYosemiteTabBarStyle() ? @"Yosemite" : @"Metal";
}

@end // MMWindowController (Private)
