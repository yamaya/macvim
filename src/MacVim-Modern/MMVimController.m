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
 * MMVimController
 *
 * Coordinates input/output to/from backend.  A MMVimController sends input
 * directly to a MMBackend, but communication from MMBackend to MMVimController
 * goes via MMAppController so that it can coordinate all incoming distributed
 * object messages.
 *
 * MMVimController does not deal with visual presentation.  Essentially it
 * should be able to run with no window present.
 *
 * Output from the backend is received in processInputQueue: (this message is
 * called from MMAppController so it is not a DO call).  Input is sent to the
 * backend via sendMessage:data: or addVimInput:.  The latter allows execution
 * of arbitrary strings in the Vim process, much like the Vim script function
 * remote_send() does.  The messages that may be passed between frontend and
 * backend are defined in an enum in MacVim.h.
 */

#import "MMAppController.h"
#import "MMFindReplaceController.h"
#import "MMVimController.h"
#import "MMVimView.h"
#import "MMWindowController.h"
#import "Miscellaneous.h"
#import "MMCoreTextView.h"
#import "MMWindow.h"


static NSString *MMDefaultToolbarImageName = @"Attention";
static int MMAlertTextFieldHeight = 22;

static const NSString *const MMToolbarMenuName = @"ToolBar";
static const NSString *const MMTouchbarMenuName = @"TouchBar";

// NOTE: By default a message sent to the backend will be dropped if it cannot
// be delivered instantly; otherwise there is a possibility that MacVim will
// 'beachball' while waiting to deliver DO messages to an unresponsive Vim
// process.  This means that you cannot rely on any message sent with
// sendMessage: to actually reach Vim.
static NSTimeInterval MMBackendProxyRequestTimeout = 0;

// Timeout used for setDialogReturn:.
static NSTimeInterval MMSetDialogReturnTimeout = 1.0;

static unsigned identifierCounter = 1;

static BOOL isUnsafeMessage(int msgid);


// HACK! AppKit private methods from NSToolTipManager.  As an alternative to
// using private methods, it would be possible to set the user default
// NSInitialToolTipDelay (in ms) on app startup, but then it is impossible to
// change the balloon delay without closing/reopening a window.
@interface NSObject (NSToolTipManagerPrivateAPI)
+ (id)sharedToolTipManager;
- (void)setInitialToolTipDelay:(double)arg1;
@end


@interface MMAlert : NSAlert {
    NSTextField *textField;
}
- (void)setTextFieldString:(NSString *)textFieldString;
- (NSTextField *)textField;
- (void)beginSheetModalForWindow:(NSWindow *)window modalDelegate:(id)delegate;
@end


@interface MMVimController (Private)
- (void)doProcessInputQueue:(NSArray *)queue;
- (void)handleMessage:(int)msgid data:(NSData *)data;
- (void)savePanelDidEnd:(NSSavePanel *)panel code:(int)code context:(void *)context;
- (void)alertDidEnd:(MMAlert *)alert code:(int)code context:(void *)context;
- (NSMenuItem *)menuItemForDescriptor:(NSArray *)desc;
- (NSMenu *)parentMenuForDescriptor:(NSArray *)desc;
- (NSMenu *)topLevelMenuForTitle:(NSString *)title;
- (void)addMenuWithDescriptor:(NSArray *)desc atIndex:(int)index;
- (void)addMenuItemWithDescriptor:(NSArray *)desc atIndex:(int)index tip:(NSString *)tip icon:(NSString *)icon keyEquivalent:(NSString *)keyEquivalent modifierMask:(int)modifierMask action:(NSString *)action isAlternate:(BOOL)isAlternate;
- (void)removeMenuItemWithDescriptor:(NSArray *)desc;
- (void)enableMenuItemWithDescriptor:(NSArray *)desc state:(BOOL)on;
- (void)addToolbarItemToDictionaryWithLabel:(NSString *)title toolTip:(NSString *)tip icon:(NSString *)icon;
- (void)addToolbarItemWithLabel:(NSString *)label tip:(NSString *)tip icon:(NSString *)icon atIndex:(int)idx;
- (void)popupMenuWithDescriptor:(NSArray *)desc atRow:(NSNumber *)row column:(NSNumber *)col; - (void)popupMenuWithAttributes:(NSDictionary *)attrs;
- (void)connectionDidDie:(NSNotification *)notification;
- (void)scheduleClose;
- (void)handleBrowseForFile:(NSDictionary *)attr;
- (void)handleShowDialog:(NSDictionary *)attr;
- (void)handleDeleteSign:(NSDictionary *)attr;
- (void)setToolTipDelay:(NSTimeInterval)seconds;
@end

/**
 */
@implementation MMVimController {
    unsigned            _identifier;
    BOOL                _initialized;
    NSMutableArray      *_popupMenuItems;
    NSToolbar           *_toolbar; // TODO: Move all toolbar code to window controller?
    NSMutableDictionary *_toolbarItemDict;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
    NSTouchBar          *_touchbar;
    NSMutableDictionary *_touchbarItemDict;
    NSMutableArray      *_touchbarItemOrder;
    NSMutableSet        *_touchbarDisabledItems;
#endif
}
@synthesize windowController = _windowController, backendProxy = _backendProxy, mainMenu = _mainMenu;
@synthesize pid = _pid, serverName = _serverName, vimState = _vimState;
@synthesize isPreloading = _isPreloading, creationDate = _creationDate, hasModifiedBuffer = _hasModifiedBuffer;
@dynamic vimControllerId;

- (instancetype)initWithBackend:(id)backend pid:(int)processIdentifier
{
    if (!(self = [super init]))
        return nil;

    // TODO: Come up with a better way of creating an identifier.
    _identifier = identifierCounter++;

    _windowController = [[MMWindowController alloc] initWithVimController:self];
    _backendProxy = backend;
    _popupMenuItems = NSMutableArray.new;
    _toolbarItemDict = NSMutableDictionary.new;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
    if (NSClassFromString(@"NSTouchBar")) {
        _touchbarItemDict = NSMutableDictionary.new;
        _touchbarItemOrder = NSMutableArray.new;
        _touchbarDisabledItems = NSMutableSet.new;
    }
#endif
    _pid = processIdentifier;
    _creationDate = NSDate.new;

    NSConnection *connection = [_backendProxy connectionForProxy];

    // TODO: Check that this will not set the timeout for the root proxy (in MMAppController).
    connection.requestTimeout = MMBackendProxyRequestTimeout;

    [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(connectionDidDie:)
                name:NSConnectionDidDieNotification object:connection];

    // Set up a main menu with only a "MacVim" menu (copied from a template
    // which itself is set up in MainMenu.nib).  The main menu is populated
    // by Vim later on.
    _mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSMenuItem *appMenuItem = MMAppController.shared.appMenuItemTemplate.copy;
    // Note: If the title of the application menu is anything but what
    // CFBundleName says then the application menu will not be typeset in
    // boldface for some reason.  (It should already be set when we copy
    // from the default main menu, but this is not the case for some
    // reason.)
    appMenuItem.title = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
    [_mainMenu addItem:appMenuItem];

    _initialized = YES;

    return self;
}

- (unsigned)vimControllerId
{
    return _identifier;
}

- (id)objectForVimStateKey:(NSString *)key
{
    return _vimState[key];
}

- (void)dropFiles:(NSArray *)filenames forceOpen:(BOOL)force
{
    filenames = normalizeFilenames(filenames);
    ASLogInfo(@"filenames=%@ force=%d", filenames, force);

    // Default to opening in tabs if layout is invalid or set to "windows".
    int layout = [NSUserDefaults.standardUserDefaults integerForKey:MMOpenLayoutKey];
    if (layout < 0 || layout > MMLayoutTabs) layout = MMLayoutTabs;

    const BOOL vertSplit = [NSUserDefaults.standardUserDefaults boolForKey:MMVerticalSplitKey];
    if (vertSplit && MMLayoutHorizontalSplit == layout) layout = MMLayoutVerticalSplit;

    NSDictionary *args = @{@"layout": @(layout), @"filenames": filenames, @"forceOpen": @(force)};
    [self sendMessage:DropFilesMsgID data:args.dictionaryAsData];

    // Add dropped files to the "Recent Files" menu.
    [NSDocumentController.sharedDocumentController noteNewRecentFilePaths:filenames];
}

- (void)file:(NSString *)filename draggedToTabAtIndex:(NSUInteger)index
{
    filename = normalizeFilename(filename);
    ASLogInfo(@"filename=%@ index=%ld", filename, index);

    NSString *fn = filename.stringByEscapingSpecialFilenameCharacters;
    [self addVimInput:[NSString stringWithFormat:@"<C-\\><C-N>:silent tabnext %ld |edit! %@<CR>", index + 1, fn]];
}

- (void)filesDraggedToTabBar:(NSArray *)filenames
{
    filenames = normalizeFilenames(filenames);
    ASLogInfo(@"%@", filenames);

    NSMutableString *input = [NSMutableString stringWithString:@"<C-\\><C-N>:silent! tabnext 9999"];
    for (NSString *filename in filenames) {
        NSString *fn = filename.stringByEscapingSpecialFilenameCharacters;
        [input appendFormat:@"|tabedit %@", fn];
    }
    [input appendString:@"<CR>"];
    [self addVimInput:input];
}

- (void)dropString:(NSString *)string
{
    ASLogInfo(@"%@", string);

    const int length = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
    if (length > 0) {
        NSMutableData *data = NSMutableData.new;
        [data appendBytes:&length length:sizeof(int)];
        [data appendBytes:string.UTF8String length:length];
        [self sendMessage:DropStringMsgID data:data];
    }
}

- (void)passArguments:(NSDictionary *)args
{
    if (!args) return;

    ASLogDebug(@"args=%@", args);

    [self sendMessage:OpenWithArgumentsMsgID data:args.dictionaryAsData];
}

- (void)sendMessage:(int)msgid data:(NSData *)data
{
    ASLogDebug(@"msg=%s (initialized=%d)", MessageStrings[msgid], _initialized);

    if (!_initialized) return;

    @try {
        [_backendProxy processInput:msgid data:data];
    } @catch (NSException *e) {
        ASLogDebug(@"processInput:data: failed: pid=%d id=%d msg=%s reason=%@", _pid, _identifier, MessageStrings[msgid], e);
    }
}

- (BOOL)sendMessageNow:(int)msgid data:(NSData *)data timeout:(NSTimeInterval)timeout
{
    // Send a message with a timeout.  USE WITH EXTREME CAUTION!  Sending
    // messages in rapid succession with a timeout may cause MacVim to beach
    // ball forever.  In almost all circumstances sendMessage:data: should be
    // used instead.

    ASLogDebug(@"msg=%s (initialized=%d)", MessageStrings[msgid], _initialized);

    if (!_initialized) return NO;

    BOOL sendOk = YES;
    NSConnection *connection = [_backendProxy connectionForProxy];
    const NSTimeInterval oldTimeout = connection.requestTimeout;

    @try {
        connection.requestTimeout = MAX(timeout, 0);

        [_backendProxy processInput:msgid data:data];
    } @catch (NSException *e) {
        sendOk = NO;
        ASLogDebug(@"processInput:data: failed: pid=%d id=%d msg=%s reason=%@", _pid, _identifier, MessageStrings[msgid], e);
    } @finally {
        connection.requestTimeout = oldTimeout;
    }

    return sendOk;
}

- (void)addVimInput:(NSString *)string
{
    ASLogDebug(@"%@", string);

    // This is a very general method of adding input to the Vim process.  It is
    // basically the same as calling remote_send() on the process (see
    // ':h remote_send').
    if (string) {
        NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
        [self sendMessage:AddInputMsgID data:data];
    }
}

- (NSString *)evaluateVimExpression:(NSString *)expression
{
    NSString *eval = nil;

    @try {
        eval = [_backendProxy evaluateExpression:expression];
        ASLogDebug(@"eval(%@)=%@", expression, eval);
    } @catch (NSException *e) {
        ASLogDebug(@"evaluateExpression: failed: pid=%d id=%d reason=%@", _pid, _identifier, e);
    }

    return eval;
}

- (id)evaluateVimExpressionCocoa:(NSString *)expression errorString:(NSString **)outErrorString
{
    id eval = nil;
    @try {
        eval = [_backendProxy evaluateExpressionCocoa:expression errorString:outErrorString];
        ASLogDebug(@"eval(%@)=%@", expression, eval);
    } @catch (NSException *e) {
        ASLogDebug(@"evaluateExpressionCocoa: failed: pid=%d id=%d reason=%@", _pid, _identifier, e);
        *outErrorString = e.reason;
    }
    return eval;
}

- (void)cleanup
{
    if (!_initialized) return;

    // Remove any delayed calls made on this object.
    [NSObject cancelPreviousPerformRequestsWithTarget:self];

    _initialized = NO;
    _toolbar.delegate = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_windowController cleanup];
}

- (void)processInputQueue:(NSArray *)queue
{
    if (!_initialized) return;

    // NOTE: This method must not raise any exceptions (see comment in the
    // calling method).
    @try {
        [self doProcessInputQueue:queue];
        [_windowController processInputQueueDidFinish];
    } @catch (NSException *e) {
        ASLogDebug(@"Exception: pid=%d id=%d reason=%@", _pid, _identifier, e);
    }
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *item = _toolbarItemDict[identifier];
    if (!item) {
        ASLogWarn(@"No toolbar item with id '%@'", identifier);
    }
    return item;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
    return nil;
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    return nil;
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
- (NSTouchBar *)makeTouchBar
{
    _touchbar = [[NSTouchBar alloc] init];
    _touchbar.delegate = self;
    
    NSMutableArray *filteredTouchbarItemOrder = NSMutableArray.new;
    for (NSString *barItemLabel in _touchbarItemOrder) {
        if (![_touchbarDisabledItems containsObject:barItemLabel]) {
            NSString *label = barItemLabel;
            if (!_touchbarItemDict[label]) {
                // The label begins and ends with '-'; decided which kind of separator
                // item it is by looking at the prefix.
                if ([label hasPrefix:@"-space"]) {
                    label = NSTouchBarItemIdentifierFixedSpaceSmall;
                } else if ([label hasPrefix:@"-flexspace"]) {
                    label = NSTouchBarItemIdentifierFlexibleSpace;
                } else {
                    label = NSTouchBarItemIdentifierFixedSpaceLarge;
                }
            }
            [filteredTouchbarItemOrder addObject:label];
        }
    }
    [filteredTouchbarItemOrder addObject:NSTouchBarItemIdentifierOtherItemsProxy];

    _touchbar.defaultItemIdentifiers = filteredTouchbarItemOrder;
    return _touchbar;
}

- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)itemId
{
    NSTouchBarItem *item = _touchbarItemDict[itemId];
    if (!item) {
        ASLogWarn(@"No touchbar item with id '%@'", itemId);
    }
    return item;
}
#endif

@end // MMVimController


@implementation MMVimController (Private)

- (void)doProcessInputQueue:(NSArray *)queue
{
    NSMutableArray *delayQueue = nil;

    const NSUInteger count = queue.count;
    if (count % 2) {
        ASLogWarn(@"Uneven number of components (%d) in command queue. Skipping...", (int)count);
        return;
    }

    for (NSUInteger i = 0; i < count; i += 2) {
        NSData *value = queue[i];
        NSData *data = queue[i + 1];

        const int msgid = *((int *)value.bytes);
        if (![NSRunLoop.currentRunLoop.currentMode isEqual:NSDefaultRunLoopMode] && isUnsafeMessage(msgid)) {
            // NOTE: Because we may be listening to DO messages in "event
            // tracking mode" we have to take extra care when doing things
            // like releasing view items (and other Cocoa objects).
            // Messages that may be potentially "unsafe" are delayed until
            // the run loop is back to default mode at which time they are
            // safe to call again.
            //   A problem with this approach is that it is hard to
            // classify which messages are unsafe.  As a rule of thumb, if
            // a message may release an object used by the Cocoa framework
            // (e.g. views) then the message should be considered unsafe.
            //   Delaying messages may have undesired side-effects since it
            // means that messages may not be processed in the order Vim
            // sent them, so beware.
            if (!delayQueue) delayQueue = NSMutableArray.new;

            ASLogDebug(@"Adding unsafe message '%s' to delay queue (mode=%@)", MessageStrings[msgid], NSRunLoop.currentRunLoop.currentMode);
            [delayQueue addObject:value];
            [delayQueue addObject:data];
        } else {
            [self handleMessage:msgid data:data];
        }
    }

    if (delayQueue) {
        ASLogDebug(@"    Flushing delay queue (%ld items)", delayQueue.count / 2);
        __weak typeof(self) zelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [zelf processInputQueue:delayQueue]; });
    }
}

- (void)handleMessage:(int)msgid data:(NSData *)data
{
    if (OpenWindowMsgID == msgid) {
        [_windowController openWindow];
        if (!_isPreloading) {
            [_windowController presentWindow:nil];
        }
    } else if (BatchDrawMsgID == msgid) {
        [_windowController.vimView.textView performBatchDrawWithData:data];
    } else if (SelectTabMsgID == msgid) {
#if 0   // NOTE: Tab selection is done inside updateTabsWithData:.
        const void *bytes = [data bytes];
        int idx = *((int*)bytes);
        [_windowController selectTabWithIndex:idx];
#endif
    } else if (UpdateTabBarMsgID == msgid) {
        [_windowController updateTabsWithData:data];
    } else if (ShowTabBarMsgID == msgid) {
        [_windowController showTabBar:YES];
        [self sendMessage:BackingPropertiesChangedMsgID data:nil];
    } else if (HideTabBarMsgID == msgid) {
        [_windowController showTabBar:NO];
        [self sendMessage:BackingPropertiesChangedMsgID data:nil];
    } else if (SetTextDimensionsMsgID == msgid || LiveResizeMsgID == msgid ||
            SetTextDimensionsNoResizeWindowMsgID == msgid ||
            SetTextDimensionsReplyMsgID == msgid) {
        const void *bytes = data.bytes;
        const int rows = *((int *)bytes);  bytes += sizeof(int);
        const int cols = *((int *)bytes);
        // NOTE: When a resize message originated in the frontend, Vim
        // acknowledges it with a reply message.  When this happens the window
        // should not move (the frontend would already have moved the window).
        [_windowController setTextDimensionsWithRows:rows
                                             columns:cols
                                              isLive:LiveResizeMsgID == msgid
                                         keepGUISize:SetTextDimensionsNoResizeWindowMsgID == msgid
                                        keepOnScreen:SetTextDimensionsReplyMsgID != msgid];
    } else if (ResizeViewMsgID == msgid) {
        [_windowController resizeView];
    } else if (SetWindowTitleMsgID == msgid) {
        const void *bytes = data.bytes;
        int len = *((int *)bytes);  bytes += sizeof(int);

        NSString *string = [[NSString alloc] initWithBytes:(void *)bytes length:len encoding:NSUTF8StringEncoding];

        // While in live resize the window title displays the dimensions of the
        // window so don't clobber this with a spurious "set title" message
        // from Vim.
        if (!_windowController.vimView.inLiveResize) _windowController.title = string;
    } else if (SetDocumentFilenameMsgID == msgid) {
        const void *bytes = data.bytes;
        int len = *((int *)bytes);  bytes += sizeof(int);

        if (len > 0) {
            NSString *filename = [[NSString alloc] initWithBytes:(void *)bytes length:len encoding:NSUTF8StringEncoding];
            _windowController.documentFilename = filename;
        } else {
            _windowController.documentFilename = @"";
        }
    } else if (AddMenuMsgID == msgid) {
        NSDictionary *attrs = [NSDictionary dictionaryWithData:data];
        [self addMenuWithDescriptor:attrs[@"descriptor"] atIndex:[attrs[@"index"] intValue]];
    } else if (AddMenuItemMsgID == msgid) {
        NSDictionary *attrs = [NSDictionary dictionaryWithData:data];
        [self addMenuItemWithDescriptor:attrs[@"descriptor"]
                      atIndex:[attrs[@"index"] intValue]
                          tip:attrs[@"tip"]
                         icon:attrs[@"icon"]
                keyEquivalent:attrs[@"keyEquivalent"]
                 modifierMask:[attrs[@"modifierMask"] intValue]
                       action:attrs[@"action"]
                  isAlternate:[attrs[@"isAlternate"] boolValue]];
    } else if (RemoveMenuItemMsgID == msgid) {
        NSDictionary *attrs = [NSDictionary dictionaryWithData:data];
        [self removeMenuItemWithDescriptor:attrs[@"descriptor"]];
    } else if (EnableMenuItemMsgID == msgid) {
        NSDictionary *attrs = [NSDictionary dictionaryWithData:data];
        [self enableMenuItemWithDescriptor:attrs[@"descriptor"] state:[attrs[@"enable"] boolValue]];
    } else if (ShowToolbarMsgID == msgid) {
        const void *bytes = data.bytes;
        const int enable = *((int*)bytes);  bytes += sizeof(int);
        const int flags = *((int*)bytes);

        int mode = NSToolbarDisplayModeDefault;
        if (flags & ToolbarLabelFlag) {
            mode = flags & ToolbarIconFlag ? NSToolbarDisplayModeIconAndLabel : NSToolbarDisplayModeLabelOnly;
        } else if (flags & ToolbarIconFlag) {
            mode = NSToolbarDisplayModeIconOnly;
        }
        const int size = flags & ToolbarSizeRegularFlag ? NSToolbarSizeModeRegular : NSToolbarSizeModeSmall;
        [_windowController showToolbar:enable size:size mode:mode];
    } else if (CreateScrollbarMsgID == msgid) {
        const void *bytes = data.bytes;
        int32_t ident = *((int32_t *)bytes);  bytes += sizeof(int32_t);
        const int type = *((int *)bytes);

        [_windowController createScrollbarWithIdentifier:ident type:type];
    } else if (DestroyScrollbarMsgID == msgid) {
        const void *bytes = data.bytes;
        int32_t ident = *((int32_t *)bytes);

        [_windowController destroyScrollbarWithIdentifier:ident];
    } else if (ShowScrollbarMsgID == msgid) {
        const void *bytes = data.bytes;
        int32_t ident = *((int32_t *)bytes);  bytes += sizeof(int32_t);
        int visible = *((int *)bytes);

        [_windowController showScrollbarWithIdentifier:ident state:visible];
    } else if (SetScrollbarPositionMsgID == msgid) {
        const void *bytes = data.bytes;
        const int32_t ident = *((int32_t *)bytes);  bytes += sizeof(int32_t);
        const int pos = *((int *)bytes);  bytes += sizeof(int);
        const int len = *((int *)bytes);

        [_windowController setScrollbarPosition:pos length:len identifier:ident];
    } else if (SetScrollbarThumbMsgID == msgid) {
        const void *bytes = data.bytes;
        const int32_t ident = *((int32_t *)bytes);  bytes += sizeof(int32_t);
        const float val = *((float *)bytes);  bytes += sizeof(float);
        const float prop = *((float *)bytes);

        [_windowController setScrollbarThumbValue:val proportion:prop identifier:ident];
    } else if (SetFontMsgID == msgid) {
        const void *bytes = data.bytes;
        float size = *((float *)bytes);  bytes += sizeof(float);
        int len = *((int *)bytes);  bytes += sizeof(int);
        NSString *name = [[NSString alloc] initWithBytes:(void*)bytes length:len encoding:NSUTF8StringEncoding];
        NSFont *font = [NSFont fontWithName:name size:size];
        if (!font) {
            // This should only happen if the system default font has changed
            // name since MacVim was compiled in which case we fall back on
            // using the user fixed width font.
            font = [NSFont userFixedPitchFontOfSize:size];
        }

        _windowController.font = font;
    } else if (SetWideFontMsgID == msgid) {
        const void *bytes = data.bytes;
        const float size = *((float *)bytes);  bytes += sizeof(float);
        const int len = *((int *)bytes);  bytes += sizeof(int);
        if (len > 0) {
            NSString *name = [[NSString alloc] initWithBytes:(void *)bytes length:len encoding:NSUTF8StringEncoding];
            _windowController.wideFont = [NSFont fontWithName:name size:size];
        } else {
            _windowController.wideFont = nil;
        }
    } else if (SetDefaultColorsMsgID == msgid) {
        const void *bytes = data.bytes;
        const unsigned bg = *((unsigned *)bytes);  bytes += sizeof(unsigned);
        const unsigned fg = *((unsigned *)bytes);

        [_windowController setDefaultColorsBackground:[NSColor colorWithArgbInt:bg]
                                           foreground:[NSColor colorWithRgbInt:fg]];
    } else if (ExecuteActionMsgID == msgid) {
        const void *bytes = data.bytes;
        const int len = *((int *)bytes);  bytes += sizeof(int);
        NSString *name = [[NSString alloc] initWithBytes:(void *)bytes length:len encoding:NSUTF8StringEncoding];

        [NSApp sendAction:NSSelectorFromString(name) to:nil from:self];
    } else if (ShowPopupMenuMsgID == msgid) {
        NSDictionary *attrs = [NSDictionary dictionaryWithData:data];

        // The popup menu enters a modal loop so delay this call so that we
        // don't block inside processInputQueue:.
        [self performSelector:@selector(popupMenuWithAttributes:) withObject:attrs afterDelay:0];
    } else if (SetMouseShapeMsgID == msgid) {
        const void *bytes = data.bytes;
        const int shape = *((int*)bytes);

        _windowController.mouseShape = shape;
    } else if (AdjustLinespaceMsgID == msgid) {
        const void *bytes = data.bytes;
        const int linespace = *((int *)bytes);

        [_windowController adjustLinespace:linespace];
    } else if (AdjustColumnspaceMsgID == msgid) {
        const void *bytes = data.bytes;
        const int columnspace = *((int *)bytes);

        [_windowController adjustColumnspace:columnspace];
    } else if (ActivateMsgID == msgid) {
        [NSApp activateIgnoringOtherApps:YES];
        [_windowController.window makeKeyAndOrderFront:self];
    } else if (SetServerNameMsgID == msgid) {
        _serverName = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } else if (EnterFullScreenMsgID == msgid) {
        const void *bytes = data.bytes;
        const int fuoptions = *((int *)bytes); bytes += sizeof(int);
        const int bg = *((int *)bytes);

        NSColor *color = [NSColor colorWithArgbInt:bg];
        [_windowController enterFullScreen:fuoptions backgroundColor:color];
    } else if (LeaveFullScreenMsgID == msgid) {
        [_windowController leaveFullScreen];
    } else if (SetBuffersModifiedMsgID == msgid) {
        const void *bytes = data.bytes;
        // state < 0  <->  some buffer modified
        // state > 0  <->  current buffer modified
        int state = *((int *)bytes);

        // NOTE: The window controller tracks whether current buffer is
        // modified or not (and greys out the proxy icon as well as putting a
        // dot in the red "close button" if necessary).  The Vim controller
        // tracks whether any buffer has been modified (used to decide whether
        // to show a warning or not when quitting).
        //
        // TODO: Make 'hasModifiedBuffer' part of the Vim state?
        _windowController.bufferModified = state > 0;
        _hasModifiedBuffer = state != 0;
    } else if (SetPreEditPositionMsgID == msgid) {
        const int *dim = (const int *)data.bytes;
        [_windowController.vimView.textView setPreEditRow:dim[0] column:dim[1]];
    } else if (EnableAntialiasMsgID == msgid) {
        _windowController.vimView.textView.antialias = YES;
    } else if (DisableAntialiasMsgID == msgid) {
        _windowController.vimView.textView.antialias = NO;
    } else if (EnableLigaturesMsgID == msgid) {
        _windowController.vimView.textView.ligatures = YES;
    } else if (DisableLigaturesMsgID == msgid) {
        _windowController.vimView.textView.ligatures = NO;
    } else if (EnableThinStrokesMsgID == msgid) {
        _windowController.vimView.textView.thinStrokes = YES;
    } else if (DisableThinStrokesMsgID == msgid) {
        _windowController.vimView.textView.thinStrokes = NO;
    } else if (SetVimStateMsgID == msgid) {
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        if (dict) _vimState = dict;
    } else if (CloseWindowMsgID == msgid) {
        [self scheduleClose];
    } else if (SetFullScreenColorMsgID == msgid) {
        const int *bg = (const int *)data.bytes;

        [_windowController setFullScreenBackgroundColor:[NSColor colorWithRgbInt:*bg]];
    } else if (ShowFindReplaceDialogMsgID == msgid) {
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        if (dict) [MMFindReplaceController.shared showWithText:dict[@"text"] flags:[dict[@"flags"] intValue]];
    } else if (ActivateKeyScriptMsgID == msgid) {
        _windowController.vimView.textView.IMActivated = YES;
    } else if (DeactivateKeyScriptMsgID == msgid) {
        _windowController.vimView.textView.IMActivated = NO;
    } else if (EnableImControlMsgID == msgid) {
        _windowController.vimView.textView.IMControlled = YES;
    } else if (DisableImControlMsgID == msgid) {
        _windowController.vimView.textView.IMControlled = NO;
    } else if (BrowseForFileMsgID == msgid) {
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        if (dict) [self handleBrowseForFile:dict];
    } else if (ShowDialogMsgID == msgid) {
        [_windowController runAfterWindowPresentedUsingBlock:^{
            NSDictionary *dict = [NSDictionary dictionaryWithData:data];
            if (dict) [self handleShowDialog:dict];
        }];
    } else if (DeleteSignMsgID == msgid) {
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        if (dict) [self handleDeleteSign:dict];
    } else if (ZoomMsgID == msgid) {
        const void *bytes = data.bytes;
        const int rows = *((int *)bytes);  bytes += sizeof(int);
        const int cols = *((int *)bytes);  bytes += sizeof(int);
        const int state = *((int *)bytes);

        [_windowController zoomWithRows:rows columns:cols state:state];
    } else if (SetWindowPositionMsgID == msgid) {
        const void *bytes = data.bytes;
        const int x = *((int *)bytes);  bytes += sizeof(int);
        int y = *((int *)bytes);

        // NOTE: Vim measures Y-coordinates from top of screen.
        y = NSMaxY(_windowController.window.screen.frame) - y;

        _windowController.topLeft = NSMakePoint(x, y);
    } else if (SetTooltipMsgID == msgid) {
        NSView<MMTextView> *textView = _windowController.vimView.textView;
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        NSString *toolTip = dict[@"toolTip"];
        if (toolTip && toolTip.length != 0)
            [textView setToolTipAtMousePoint:toolTip];
        else
            [textView setToolTipAtMousePoint:nil];
    } else if (SetTooltipDelayMsgID == msgid) {
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        if (dict[@"delay"]) [self setToolTipDelay:[dict[@"delay"] floatValue]];
    } else if (AddToMRUMsgID == msgid) {
        NSDictionary *dict = [NSDictionary dictionaryWithData:data];
        NSArray *filenames = dict ? dict[@"filenames"] : nil;
        if (filenames) [NSDocumentController.sharedDocumentController noteNewRecentFilePaths:filenames];
    } else if (SetBlurRadiusMsgID == msgid) {
        const void *bytes = data.bytes;
        const int radius = *((int *)bytes);
        _windowController.blurRadius = radius;
    // IMPORTANT: When adding a new message, make sure to update
    // isUnsafeMessage() if necessary!
    } else {
        ASLogWarn(@"Unknown message received (msgid=%d)", msgid);
    }
}

- (void)savePanelDidEnd:(NSSavePanel *)panel code:(int)code context:(void *)context
{
    NSString *path = nil;
#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10)
    #define OKButton NSModalResponseOK
#else
    #define OKButton NSOKButton
#endif
    if (code == OKButton && panel.URL.isFileURL) {
        path = panel.URL.path;
    }
    ASLogDebug(@"Open/save panel path=%@", path);

    // NOTE!  This causes the sheet animation to run its course BEFORE the rest
    // of this function is executed.  If we do not wait for the sheet to
    // disappear before continuing it can happen that the controller is
    // released from under us (i.e. we'll crash and burn) because this
    // animation is otherwise performed in the default run loop mode!
    [panel orderOut:self];

    // NOTE! setDialogReturn: is a synchronous call so set a proper timeout to
    // avoid waiting forever for it to finish.  We make this a synchronous call
    // so that we can be fairly certain that Vim doesn't think the dialog box
    // is still showing when MacVim has in fact already dismissed it.
    NSConnection *connection = [_backendProxy connectionForProxy];
    const NSTimeInterval oldTimeout = connection.requestTimeout;

    @try {
        connection.requestTimeout = MMSetDialogReturnTimeout;

        [_backendProxy setDialogReturn:path];

        // Add file to the "Recent Files" menu (this ensures that files that
        // are opened/saved from a :browse command are added to this menu).
        if (path) [NSDocumentController.sharedDocumentController noteNewRecentFilePath:path];
    } @catch (NSException *e) {
        ASLogDebug(@"Exception: pid=%d id=%d reason=%@", _pid, _identifier, e);
    } @finally {
        connection.requestTimeout = oldTimeout;
    }
}

- (void)alertDidEnd:(MMAlert *)alert code:(int)code context:(void *)context
{
    NSArray *dialogReturn = nil;

    code = code - NSAlertFirstButtonReturn + 1;

    if ([alert isKindOfClass:MMAlert.class] && alert.textField) {
        dialogReturn = @[@(code), alert.textField.stringValue];
    } else {
        dialogReturn = @[@(code)];
    }

    ASLogDebug(@"Alert return=%@", dialogReturn);

    // NOTE!  This causes the sheet animation to run its course BEFORE the rest
    // of this function is executed.  If we do not wait for the sheet to
    // disappear before continuing it can happen that the controller is
    // released from under us (i.e. we'll crash and burn) because this
    // animation is otherwise performed in the default run loop mode!
    [alert.window orderOut:self];

    @try {
        [_backendProxy setDialogReturn:dialogReturn];
    } @catch (NSException *e) {
        ASLogDebug(@"setDialogReturn: failed: pid=%d id=%d reason=%@", _pid, _identifier, e);
    }
}

- (NSMenuItem *)menuItemForDescriptor:(NSArray *)desc
{
    if (desc.count == 0) return nil;

    NSString *rootName = desc.firstObject;
    NSArray *rootItems = [rootName hasPrefix:@"PopUp"] ? _popupMenuItems : _mainMenu.itemArray;

    NSMenuItem *item = nil;
    NSUInteger i;
    for (i = 0; i < rootItems.count; ++i) {
        item = rootItems[i];
        if ([item.title isEqual:rootName])
            break;
    }

    if (i == rootItems.count) return nil;

    for (i = 1; i < desc.count; ++i) {
        item = [item.submenu itemWithTitle:desc[i]];
        if (!item) break;
    }

    return item;
}

- (NSMenu *)parentMenuForDescriptor:(NSArray *)desc
{
    if (desc.count == 0) return nil;

    NSString *rootName = desc.firstObject;
    NSArray *rootItems = [rootName hasPrefix:@"PopUp"] ? _popupMenuItems : _mainMenu.itemArray;

    NSMenu *menu = nil;
    NSUInteger i;
    for (i = 0; i < rootItems.count; ++i) {
        NSMenuItem *item = rootItems[i];
        if ([item.title isEqual:rootName]) {
            menu = item.submenu;
            break;
        }
    }

    if (!menu) return nil;

    const NSUInteger count = desc.count - 1;
    for (i = 1; i < count; ++i) {
        NSMenuItem *item = [menu itemWithTitle:desc[i]];
        menu = item.submenu;
        if (!menu) break;
    }

    return menu;
}

- (NSMenu *)topLevelMenuForTitle:(NSString *)title
{
    for (NSMenuItem *item in _popupMenuItems)
        if ([title isEqual:item.title]) return item.submenu;
    for (NSUInteger i = 0; i < _mainMenu.numberOfItems; ++i) {
        NSMenuItem *item = [_mainMenu itemAtIndex:i];
        if ([title isEqual:item.title]) return item.submenu;
    }
    return nil;
}

- (void)addMenuWithDescriptor:(NSArray *)desc atIndex:(int)index
{
    if (!(desc.count != 0 && index >= 0)) return;

    NSString *rootName = desc.firstObject;
    if ([rootName isEqual:MMToolbarMenuName]) {
        // The toolbar only has one menu, we take this as a hint to create a
        // toolbar, then we return.
        if (!_toolbar) {
            // NOTE! Each toolbar must have a unique identifier, else each
            // window will have the same toolbar.
            _toolbar = [[NSToolbar alloc] initWithIdentifier:@(_identifier).stringValue];
            _toolbar.showsBaselineSeparator = NO;
            _toolbar.delegate = self;
            _toolbar.displayMode = NSToolbarDisplayModeIconOnly;
            _toolbar.sizeMode = NSToolbarSizeModeSmall;
            _windowController.toolbar = _toolbar;
        }
        return;
    }

    if ([rootName isEqual:MMTouchbarMenuName])
        return;

    // This is either a main menu item or a popup menu item.
    NSString *title = desc.lastObject;
    NSMenuItem *item = NSMenuItem.new;
    item.title = title;
    item.submenu = [[NSMenu alloc] initWithTitle:title];

    NSMenu *parent = [self parentMenuForDescriptor:desc];
    if (!parent && [rootName hasPrefix:@"PopUp"]) {
        if (_popupMenuItems.count <= index) {
            [_popupMenuItems addObject:item];
        } else {
            [_popupMenuItems insertObject:item atIndex:index];
        }
    } else {
        // If descriptor has no parent and its not a popup (or toolbar) menu,
        // then it must belong to main menu.
        if (!parent) parent = _mainMenu;

        if (parent.numberOfItems <= index) {
            [parent addItem:item];
        } else {
            [parent insertItem:item atIndex:index];
        }
    }
}

- (void)addMenuItemWithDescriptor:(NSArray *)desc atIndex:(int)index tip:(NSString *)tip icon:(NSString *)icon keyEquivalent:(NSString *)keyEquivalent modifierMask:(int)modifierMask action:(NSString *)action isAlternate:(BOOL)isAlternate
{
    if (!(desc.count > 1 && index >= 0)) return;

    NSString *title = desc.lastObject;
    NSString *rootName = desc.firstObject;

    if ([rootName isEqual:MMToolbarMenuName]) {
        if (_toolbar && desc.count == 2)
            [self addToolbarItemWithLabel:title tip:tip icon:icon atIndex:index];
        return;
    }

    if ([rootName isEqual:MMTouchbarMenuName]) {
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
        if (NSClassFromString(@"NSTouchBar")) {
            if (desc.count == 2)
                [self addTouchbarItemWithLabel:title icon:icon atIndex:index];
        }
#endif
        return;
    }

    NSMenu *parent = [self parentMenuForDescriptor:desc];
    if (!parent) {
        ASLogWarn(@"Menu item '%@' has no parent", [desc componentsJoinedByString:@"->"]);
        return;
    }

    NSMenuItem *item = nil;
    if (0 == title.length || ([title hasPrefix:@"-"] && [title hasSuffix:@"-"])) {
        item = NSMenuItem.separatorItem;
        item.title = title;
    } else {
        item = NSMenuItem.new;
        item.title = title;

        // Note: It is possible to set the action to a message that "doesn't
        // exist" without problems.  We take advantage of this when adding
        // "dummy items" e.g. when dealing with the "Recent Files" menu (in
        // which case a recentFilesDummy: action is set, although it is never
        // used).
        if (action.length != 0)
            item.action = NSSelectorFromString(action);
        else
            item.action = @selector(vimMenuItemAction:);
        if (tip.length != 0) item.toolTip = tip;
        if (keyEquivalent.length != 0) {
            item.keyEquivalent = keyEquivalent;
            item.keyEquivalentModifierMask = modifierMask;
        }
        item.alternate = isAlternate;

        // The tag is used to indicate whether Vim thinks a menu item should be
        // enabled or disabled.  By default Vim thinks menu items are enabled.
        item.tag = 1;
    }

    if (parent.numberOfItems <= index) {
        [parent addItem:item];
    } else {
        [parent insertItem:item atIndex:index];
    }
}

- (void)removeMenuItemWithDescriptor:(NSArray *)desc
{
    if (desc.count == 0) return;

    NSString *title = desc.lastObject;
    NSString *rootName = desc.firstObject;
    if ([rootName isEqual:MMToolbarMenuName]) {
        if (_toolbar) {
            // Only remove toolbar items, never actually remove the toolbar
            // itself or strange things may happen.
            if (desc.count == 2) {
                const NSUInteger i = [_toolbar indexOfItemWithItemIdentifier:title];
                if (i != NSNotFound) [_toolbar removeItemAtIndex:i];
            }
        }
        return;
    }

    if ([rootName isEqual:MMTouchbarMenuName]){
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
        if (NSClassFromString(@"NSTouchBar")) {
            if ([desc count] == 2) {
                [_touchbarItemOrder removeObject:title];
                [_touchbarItemDict removeObjectForKey:title];
                [_touchbarDisabledItems removeObject:title];
                _windowController.touchBar = nil;
            }
        }
#endif
        return;
    }

    NSMenuItem *item = [self menuItemForDescriptor:desc];
    if (!item) {
        ASLogWarn(@"Failed to remove menu item, descriptor not found: %@", [desc componentsJoinedByString:@"->"]);
        return;
    }

    if (item.menu == NSApp.mainMenu || !item.menu) {
        // NOTE: To be on the safe side we try to remove the item from
        // both arrays (it is ok to call removeObject: even if an array
        // does not contain the object to remove).
        [_popupMenuItems removeObject:item];
    }

    if (item.menu) [item.menu removeItem:item];
}

- (void)enableMenuItemWithDescriptor:(NSArray *)desc state:(BOOL)on
{
    if (desc.count == 0) return;

    NSString *rootName = desc.firstObject;
    if ([rootName isEqual:MMToolbarMenuName]) {
        if (_toolbar && desc.count == 2) {
            [[_toolbar itemWithItemIdentifier:desc.lastObject] setEnabled:on];
        }
    } else {
        return;
    }

    if ([rootName isEqual:MMTouchbarMenuName]) {
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
        if (NSClassFromString(@"NSTouchBar")) {
            if (desc.count == 2) {
                NSString *title = desc.lastObject;
                if (on)
                    [_touchbarDisabledItems removeObject:title];
                else
                    [_touchbarDisabledItems addObject:title];
                _windowController.touchBar = nil;
            }
        }
#endif
        return;
    }

    // Use tag to set whether item is enabled or disabled instead of
    // calling setEnabled:.  This way the menus can autoenable themselves
    // but at the same time Vim can set if a menu is enabled whenever it
    // wants to.
    [[self menuItemForDescriptor:desc] setTag:on];
}

- (void)addToolbarItemToDictionaryWithLabel:(NSString *)title toolTip:(NSString *)tip icon:(NSString *)icon
{
    // If the item corresponds to a separator then do nothing, since it is
    // already defined by Cocoa.
    if (!title || [title isEqual:NSToolbarSeparatorItemIdentifier]
               || [title isEqual:NSToolbarSpaceItemIdentifier]
               || [title isEqual:NSToolbarFlexibleSpaceItemIdentifier])
        return;

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:title];
    [item setLabel:title];
    [item setToolTip:tip];
    [item setAction:@selector(vimToolbarItemAction:)];
    [item setAutovalidates:NO];

    NSImage *img = [NSImage imageNamed:icon];
    if (!img) {
        img = [[NSImage alloc] initByReferencingFile:icon];
        if (!(img && [img isValid]))
            img = nil;
    }
    if (!img) {
        ASLogNotice(@"Could not find image with name '%@' to use as toolbar image for identifier '%@'; using default toolbar icon '%@' instead.", icon, title, MMDefaultToolbarImageName);

        img = [NSImage imageNamed:MMDefaultToolbarImageName];
    }

    item.image = img;

    _toolbarItemDict[title] = item;
}

- (void)addToolbarItemWithLabel:(NSString *)label
                            tip:(NSString *)tip
                           icon:(NSString *)icon
                        atIndex:(int)idx
{
    if (!_toolbar) return;

    // Check for separator items.
    if (!label) {
        label = NSToolbarSeparatorItemIdentifier;
    } else if ([label length] >= 2 && [label hasPrefix:@"-"]
                                   && [label hasSuffix:@"-"]) {
        // The label begins and ends with '-'; decided which kind of separator
        // item it is by looking at the prefix.
        if ([label hasPrefix:@"-space"]) {
            label = NSToolbarSpaceItemIdentifier;
        } else if ([label hasPrefix:@"-flexspace"]) {
            label = NSToolbarFlexibleSpaceItemIdentifier;
        } else {
            label = NSToolbarSeparatorItemIdentifier;
        }
    }

    [self addToolbarItemToDictionaryWithLabel:label toolTip:tip icon:icon];

    int maxIdx = [[_toolbar items] count];
    if (maxIdx < idx) idx = maxIdx;

    [_toolbar insertItemWithItemIdentifier:label atIndex:idx];
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_12_2
- (void)addTouchbarItemWithLabel:(NSString *)label icon:(NSString *)icon atIndex:(int)idx
{
    // Check for separator items.
    if (!label) {
        label = NSTouchBarItemIdentifierFixedSpaceLarge;
    } else if (label.length >= 2 && [label hasPrefix:@"-"]
                                 && [label hasSuffix:@"-"]) {
        // These will be converted to fixed/flexible space identifiers later, when "makeTouchBar" is called.
    } else {
        NSButton* button = [NSButton buttonWithTitle:label target:_windowController action:@selector(vimTouchbarItemAction:)];
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:label];
        NSImage *img = [NSImage imageNamed:icon];

        if (!img) {
            img = [[NSImage alloc] initByReferencingFile:icon];
            if (!(img && img.isValid))
                img = nil;
        }
        if (img) {
            button.image = img;
            button.imagePosition = NSImageOnly;
        }

        item.view = button;
        _touchbarItemDict[label] = item;
    }

    int maxIdx = _touchbarItemOrder.count;
    if (maxIdx < idx) idx = maxIdx;
    [_touchbarItemOrder insertObject:label atIndex:idx];

    _windowController.touchBar = nil;
}
#endif

- (void)popupMenuWithDescriptor:(NSArray *)desc
                          atRow:(NSNumber *)row
                         column:(NSNumber *)col
{
    NSMenu *menu = [[self menuItemForDescriptor:desc] submenu];
    if (!menu) return;

    id textView = [[_windowController vimView] textView];
    NSPoint pt;
    if (row && col) {
        // TODO: Let textView convert (row,col) to NSPoint.
        int r = [row intValue];
        int c = [col intValue];
        NSSize cellSize = [textView cellSize];
        pt = NSMakePoint((c+1)*cellSize.width, (r+1)*cellSize.height);
        pt = [textView convertPoint:pt toView:nil];
    } else {
        pt = [[_windowController window] mouseLocationOutsideOfEventStream];
    }

    NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
                           location:pt
                      modifierFlags:0
                          timestamp:0
                       windowNumber:_windowController.window.windowNumber
                            context:nil
                        eventNumber:0
                         clickCount:0
                           pressure:1.0];

    [NSMenu popUpContextMenu:menu withEvent:event forView:textView];
}

- (void)popupMenuWithAttributes:(NSDictionary *)attrs
{
    if (!attrs) return;

    [self popupMenuWithDescriptor:[attrs objectForKey:@"descriptor"]
                            atRow:[attrs objectForKey:@"row"]
                           column:[attrs objectForKey:@"column"]];
}

- (void)connectionDidDie:(NSNotification *)notification
{
    ASLogDebug(@"%@", notification);
    [self scheduleClose];
}

- (void)scheduleClose
{
    ASLogDebug(@"pid=%d id=%d", _pid, _identifier);

    // NOTE!  This message can arrive at pretty much anytime, e.g. while
    // the run loop is the 'event tracking' mode.  This means that Cocoa may
    // well be in the middle of processing some message while this message is
    // received.  If we were to remove the vim controller straight away we may
    // free objects that Cocoa is currently using (e.g. view objects).  The
    // following call ensures that the vim controller is not released until the
    // run loop is back in the 'default' mode.
    // Also, since the app may be multithreaded (e.g. as a result of showing
    // the open panel) we have to ensure this call happens on the main thread,
    // else there is a race condition that may lead to a crash.
    [MMAppController.shared
            performSelectorOnMainThread:@selector(removeVimController:)
                             withObject:self
                          waitUntilDone:NO
                                  modes:[NSArray arrayWithObject:
                                         NSDefaultRunLoopMode]];
}

// NSSavePanel delegate
- (void)panel:(id)sender willExpand:(BOOL)expanding
{
    // Show or hide the "show hidden files" button
    if (expanding) {
        [sender setAccessoryView:showHiddenFilesView()];
    } else {
        [sender setShowsHiddenFiles:NO];
        [sender setAccessoryView:nil];
    }
}

- (void)handleBrowseForFile:(NSDictionary *)attr
{
    if (!_initialized) return;

    NSString *dir = attr[@"dir"];
    const BOOL saving = [attr[@"saving"] boolValue];
    const BOOL browsedir = [attr[@"browsedir"] boolValue];

    if (!dir) {
        // 'dir == nil' means: set dir to the pwd of the Vim process, or let
        // open dialog decide (depending on the below user default).
        if ([NSUserDefaults.standardUserDefaults boolForKey:MMDialogsTrackPwdKey]) dir = _vimState[@"pwd"];
    }

    dir = dir.stringByExpandingTildeInPath;
    NSURL *dirURL = dir ? [NSURL fileURLWithPath:dir isDirectory:YES] : nil;

    if (saving) {
        NSSavePanel *panel = NSSavePanel.savePanel;
        // The delegate will be notified when the panel is expanded at which
        // time we may hide/show the "show hidden files" button (this button is
        // always visible for the open panel since it is always expanded).
        panel.delegate = self;
        if (panel.isExpanded) panel.accessoryView = showHiddenFilesView();
        if (dirURL) panel.directoryURL = dirURL;

        [panel beginSheetModalForWindow:_windowController.window completionHandler:^(NSInteger code) {
            [self savePanelDidEnd:panel code:code context:nil];
        }];
    } else {
        NSOpenPanel *panel = NSOpenPanel.openPanel;
        panel.allowsMultipleSelection = NO;
        panel.accessoryView = showHiddenFilesView();

        if (browsedir) {
            panel.canChooseDirectories = YES;
            panel.canChooseFiles = NO;
        }

        if (dirURL) panel.directoryURL = dirURL;

        [panel beginSheetModalForWindow:_windowController.window completionHandler:^(NSInteger code) {
            [self savePanelDidEnd:panel code:code context:nil];
        }];
    }
}

- (void)handleShowDialog:(NSDictionary *)attr
{
    if (!_initialized) return;

    NSArray *buttonTitles = attr[@"buttonTitles"];
    if (!buttonTitles || buttonTitles.count == 0) return;

    NSString *field = attr[@"textFieldString"];
    NSString *informative = attr[@"informativeText"];

    MMAlert *alert = MMAlert.new;
    if (field) alert.textFieldString = field; // NOTE! This has to be done before setting the informative text.
    alert.alertStyle = [attr[@"alertStyle"] intValue];
    alert.messageText = attr[@"messageText"]? : @"";
  if (informative) alert.informativeText = informative;
    else if (field) alert.informativeText = @"";

    for (NSString *title in buttonTitles) {
        NSString * t = title;
        // NOTE: The title of the button may contain the character '&' to
        // indicate that the following letter should be the key equivalent
        // associated with the button.  Extract this letter and lowercase it.
        NSString *keyEquivalent = nil;
        const NSRange hotkeyRange = [t rangeOfString:@"&"];
        if (NSNotFound != hotkeyRange.location) {
            if (t.length > NSMaxRange(hotkeyRange)) {
                const NSRange keyEquivRange = NSMakeRange(hotkeyRange.location + 1, 1);
                keyEquivalent = [[t substringWithRange:keyEquivRange] lowercaseString];
            }
            NSMutableString *string = [NSMutableString stringWithString:t];
            [string deleteCharactersInRange:hotkeyRange];
            t = string;
        }

        [alert addButtonWithTitle:t];

        // Set key equivalent for the button, but only if NSAlert hasn't
        // already done so.  (Check the documentation for
        // - [NSAlert addButtonWithTitle:] to see what key equivalents are
        // automatically assigned.)
        NSButton *button = alert.buttons.lastObject;
        if (button.keyEquivalent.length == 0 && keyEquivalent) {
            button.keyEquivalent = keyEquivalent;
        }
    }

    [alert beginSheetModalForWindow:_windowController.window modalDelegate:self];
}

- (void)handleDeleteSign:(NSDictionary *)attr
{
    NSView<MMTextView> *view = _windowController.vimView.textView;
    [view deleteSign:attr[@"imgName"]];
}

- (void)setToolTipDelay:(NSTimeInterval)seconds
{
    // HACK! NSToolTipManager is an AppKit private class.
    static Class TTM = nil;
    if (!TTM) TTM = NSClassFromString(@"NSToolTipManager");

    if (seconds < 0) seconds = 0;

    if (TTM) {
        [TTM.sharedToolTipManager setInitialToolTipDelay:seconds];
    } else {
        ASLogNotice(@"Failed to get NSToolTipManager");
    }
}

@end // MMVimController (Private)

/**
 */
@implementation MMAlert

- (void)setTextFieldString:(NSString *)stringn
{
    textField = NSTextField.new;
    textField.stringValue = stringn;
}

- (NSTextField *)textField
{
    return textField;
}

- (void)setInformativeText:(NSString *)text
{
    if (textField) {
        // HACK! Add some space for the text field.
        [super setInformativeText:[text stringByAppendingString:@"\n\n\n"]];
    } else {
        [super setInformativeText:text];
    }
}

- (void)beginSheetModalForWindow:(NSWindow *)window modalDelegate:(id)delegate
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10
    [super beginSheetModalForWindow:window completionHandler:^(NSModalResponse code) {
        [delegate alertDidEnd:self code:code context:nil];
    }];
#else
    [super beginSheetModalForWindow:window modalDelegate:delegate didEndSelector:@selector(alertDidEnd:code:context:) contextInfo:nil];
#endif
    // HACK! Place the input text field at the bottom of the informative text
    // (which has been made a bit larger by adding newline characters).
    NSView *contentView = self.window.contentView;
    NSRect rect = contentView.frame;
    rect.origin.y = rect.size.height;

    for (NSView *view in contentView.subviews) {
        if ([view isKindOfClass:NSTextField.class] && view.frame.origin.y < rect.origin.y) {
            // NOTE: The informative text field is the lowest NSTextField in
            // the alert dialog.
            rect = view.frame;
        }
    }

    rect.size.height = MMAlertTextFieldHeight;
    textField.frame = rect;
    [contentView addSubview:textField];
    [textField becomeFirstResponder];
}

@end // MMAlert


static BOOL isUnsafeMessage(int msgid)
{
    // Messages that may release Cocoa objects must be added to this list.  For
    // example, UpdateTabBarMsgID may delete NSTabViewItem objects so it goes
    // on this list.
    static const int messages[] = { // REASON MESSAGE IS ON THIS LIST:
        //OpenWindowMsgID,          // Changes lots of state
        UpdateTabBarMsgID,          // May delete NSTabViewItem
        RemoveMenuItemMsgID,        // Deletes NSMenuItem
        DestroyScrollbarMsgID,      // Deletes NSScroller
        ExecuteActionMsgID,         // Impossible to predict
        ShowPopupMenuMsgID,         // Enters modal loop
        ActivateMsgID,              // ?
        EnterFullScreenMsgID,       // Modifies delegate of window controller
        LeaveFullScreenMsgID,       // Modifies delegate of window controller
        CloseWindowMsgID,           // See note below
        BrowseForFileMsgID,         // Enters modal loop
        ShowDialogMsgID,            // Enters modal loop
    };

    // NOTE about CloseWindowMsgID: If this arrives at the same time as say
    // ExecuteActionMsgID, then the "execute" message will be lost due to it
    // being queued and handled after the "close" message has caused the
    // controller to cleanup...UNLESS we add CloseWindowMsgID to the list of
    // unsafe messages.  This is the _only_ reason it is on this list (since
    // all that happens in response to it is that we schedule another message
    // for later handling).
    for (size_t i = 0; i < sizeof(messages) / sizeof(messages[0]); ++i)
        if (msgid == messages[i])
            return YES;

    return NO;
}
