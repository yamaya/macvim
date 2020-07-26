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
 * MMBackend
 *
 * MMBackend communicates with the frontend (MacVim).  It maintains a queue of
 * output which is flushed to the frontend under controlled circumstances (so
 * as to maintain a steady framerate).  Input from the frontend is also handled
 * here.
 *
 * The frontend communicates with the backend via the MMBackendProtocol.  In
 * particular, input is sent to the backend via processInput:data: and Vim
 * state can be queried from the frontend with evaluateExpression:.
 *
 * It is very important to realize that all state is held by the backend, the
 * frontend must either ask for state [MMBackend evaluateExpression:] or wait
 * for the backend to update [MMAppController processInput:forIdentifier:].
 *
 * The client/server functionality of Vim is handled by the backend.  It sets
 * up a named NSConnection to which other Vim processes can connect.
 */

#import "MMBackend.h"
#import "NSString+Vim.h"
#import "MMEventUtils.h"

// NOTE: Colors in MMBackend are stored as unsigned ints on the form 0xaarrggbb
// whereas colors in Vim are int without the alpha component.  Also note that
// 'transp' is assumed to be a value between 0 and 100.
#define MM_COLOR(col) \
    ((unsigned)( ((col)&0xffffff) | 0xff000000 ))
#define MM_COLOR_WITH_TRANSP(col,transp) \
    ((unsigned)( ((col)&0xffffff) | ((((unsigned)((((100-(transp))*255)/100)+.5f))&0xff)<<24) ))

// Values for window layout (must match values in main.c).
#define WIN_HOR     1       // "-o" horizontally split windows
#define WIN_VER     2       // "-O" vertically split windows
#define WIN_TABS    3       // "-p" windows on tab pages

static unsigned MMServerMax = 1000;

// In gui_macvim.m
vimmenu_T *menu_for_descriptor(NSArray *desc);

static id evalExprCocoa(NSString * expr, NSString ** errstr);

extern void im_preedit_start_macvim();
extern void im_preedit_end_macvim();
extern void im_preedit_abandon_macvim();
extern void im_preedit_changed_macvim(const char *preedit_string, int cursor_index);

enum {
    MMBlinkStateNone = 0,
    MMBlinkStateOn,
    MMBlinkStateOff
};

static NSString *MMSymlinkWarningString =
    @"\n\n\tMost likely this is because you have symlinked directly to\n"
     "\tthe Vim binary, which Cocoa does not allow.  Please use an\n"
     "\talias or the mvim shell script instead.  If you have not used\n"
     "\ta symlink, then your MacVim.app bundle is incomplete.\n\n";


// Keycodes recognized by Vim (struct taken from gui_x11.c and gui_w48.c)
// (The key codes were taken from Carbon/HIToolbox/Events.)
static struct _SpecialKey {
    unsigned    keysym;
    char_u      code0;
    char_u      code1;
} specialKeys[] = {
    {0x7e /*kVK_UpArrow*/,       'k', 'u'},
    {0x7d /*kVK_DownArrow*/,     'k', 'd'},
    {0x7b /*kVK_LeftArrow*/,     'k', 'l'},
    {0x7c /*kVK_RightArrow*/,    'k', 'r'},

    {0x7a /*kVK_F1*/,            'k', '1'},
    {0x78 /*kVK_F2*/,            'k', '2'},
    {0x63 /*kVK_F3*/,            'k', '3'},
    {0x76 /*kVK_F4*/,            'k', '4'},
    {0x60 /*kVK_F5*/,            'k', '5'},
    {0x61 /*kVK_F6*/,            'k', '6'},
    {0x62 /*kVK_F7*/,            'k', '7'},
    {0x64 /*kVK_F8*/,            'k', '8'},
    {0x65 /*kVK_F9*/,            'k', '9'},
    {0x6d /*kVK_F10*/,           'k', ';'},

    {0x67 /*kVK_F11*/,           'F', '1'},
    {0x6f /*kVK_F12*/,           'F', '2'},
    {0x69 /*kVK_F13*/,           'F', '3'},
    {0x6b /*kVK_F14*/,           'F', '4'},
    {0x71 /*kVK_F15*/,           'F', '5'},
    {0x6a /*kVK_F16*/,           'F', '6'},
    {0x40 /*kVK_F17*/,           'F', '7'},
    {0x4f /*kVK_F18*/,           'F', '8'},
    {0x50 /*kVK_F19*/,           'F', '9'},
    {0x5a /*kVK_F20*/,           'F', 'A'},

    {0x72 /*kVK_Help*/,          '%', '1'},
    {0x33 /*kVK_Delete*/,        'k', 'b'},
    {0x75 /*kVK_ForwardDelete*/, 'k', 'D'},
    {0x73 /*kVK_Home*/,          'k', 'h'},
    {0x77 /*kVK_End*/,           '@', '7'},
    {0x74 /*kVK_PageUp*/,        'k', 'P'},
    {0x79 /*kVK_PageDown*/,      'k', 'N'},

    /* Keypad keys: */
    {0x45 /*kVK_ANSI_KeypadPlus*/,       'K', '6'},
    {0x4e /*kVK_ANSI_KeypadMinus*/,      'K', '7'},
    {0x4b /*kVK_ANSI_KeypadDivide*/,     'K', '8'},
    {0x43 /*kVK_ANSI_KeypadMultiply*/,   'K', '9'},
    {0x4c /*kVK_ANSI_KeypadEnter*/,      'K', 'A'},
    {0x41 /*kVK_ANSI_KeypadDecimal*/,    'K', 'B'},
    {0x47 /*kVK_ANSI_KeypadClear*/,      KS_EXTRA, (char_u)KE_KDEL},

    {0x52 /*kVK_ANSI_Keypad0*/,  'K', 'C'},
    {0x53 /*kVK_ANSI_Keypad1*/,  'K', 'D'},
    {0x54 /*kVK_ANSI_Keypad2*/,  'K', 'E'},
    {0x55 /*kVK_ANSI_Keypad3*/,  'K', 'F'},
    {0x56 /*kVK_ANSI_Keypad4*/,  'K', 'G'},
    {0x57 /*kVK_ANSI_Keypad5*/,  'K', 'H'},
    {0x58 /*kVK_ANSI_Keypad6*/,  'K', 'I'},
    {0x59 /*kVK_ANSI_Keypad7*/,  'K', 'J'},
    {0x5b /*kVK_ANSI_Keypad8*/,  'K', 'K'},
    {0x5c /*kVK_ANSI_Keypad9*/,  'K', 'L'},

    /* Keys that we want to be able to use any modifier with: */
    {0x31 /*kVK_Space*/,         ' ', NUL},
    {0x30 /*kVK_Tab*/,           TAB, NUL},
    {0x35 /*kVK_Escape*/,        ESC, NUL},
    {0x24 /*kVK_Return*/,        CAR, NUL},

    /* End of list marker: */
    {0, 0, 0}
};
typedef struct _SpecialKey SpecialKey;

extern GuiFont gui_mch_retain_font(GuiFont font);


@interface NSString (MMServerNameCompare)
- (NSComparisonResult)serverNameCompare:(NSString *)string;
@end

/**
 */
@interface MMBackend (Private)
- (void)clearDrawData;
- (void)didChangeWholeLine;
- (void)waitForDialogReturn;
- (void)insertVimStateMessage;
- (void)processInputQueue;
- (void)handleInputEvent:(int)msgid data:(NSData *)data;
- (void)doKeyDown:(NSString *)key keyCode:(unsigned)code modifiers:(int)modifiers;
- (BOOL)handleSpecialKey:(NSString *)key keyCode:(unsigned)code modifiers:(int)modifiers;
- (BOOL)handleMacMetaKey:(int)ikey modifiers:(int)modifiers;
- (void)queueMessage:(int)msgid data:(NSData *)data;
- (void)connectionDidDie:(NSNotification *)notification;
- (void)blinkTimerFired:(NSTimer *)timer;
- (void)focusChange:(BOOL)on;
- (void)handleToggleToolbar;
- (void)handleScrollbarEvent:(NSData *)data;
- (void)handleSetFont:(NSData *)data;
- (void)handleDropFiles:(NSData *)data;
- (void)handleDropString:(NSData *)data;
- (void)startOdbEditWithArguments:(NSDictionary *)args;
- (void)handleXcodeMod:(NSData *)data;
- (void)handleOpenWithArguments:(NSDictionary *)args;
- (int)checkForModifiedBuffers;
- (void)addInput:(NSString *)input;
- (void)redrawScreen;
- (void)handleFindReplace:(NSDictionary *)args;
- (void)handleMarkedText:(NSData *)data;
- (void)handleGesture:(NSData *)data;
#ifdef FEAT_BEVAL
- (void)bevalCallback:(id)sender;
#endif
#ifdef MESSAGE_QUEUE
- (void)checkForProcessEvents:(NSTimer *)timer;
#endif
@end

/**
 */
@interface MMBackend (ClientServer)
- (NSString *)connectionNameFromServerName:(NSString *)name;
- (NSConnection *)connectionForServerName:(NSString *)name;
- (NSConnection *)connectionForServerPort:(int)port;
- (void)serverConnectionDidDie:(NSNotification *)notification;
- (void)addClient:(NSDistantObject *)client;
- (NSString *)alternateServerNameForName:(NSString *)name;
@end

/**
 */
@implementation MMBackend {
    unsigned            _defaultBackgroundColor;
    unsigned            _defaultForegroundColor;
    NSDictionary        *_colors;
    NSDictionary        *_systemColors;
    NSMutableArray      *_outputQueue;
    NSMutableArray      *_inputQueue;
    NSMutableData       *_drawData;
    NSConnection        *_vimServerConnection;
    id                  _appProxy;
    unsigned            _identifier;
    id                  _dialogReturn;
    int                 _blinkState;
    NSTimer             *_blinkTimer;
    NSTimeInterval      _blinkWaitInterval;
    NSTimeInterval      _blinkOnInterval;
    NSTimeInterval      _blinkOffInterval;
    NSMutableDictionary *_connections;
    NSMutableDictionary *_clients;
    NSMutableDictionary *_serverReplyDict;
    NSString            *_alternateServerName;
    GuiFont             _oldWideFont;
    BOOL                _teminating;
    BOOL                _flushDisabled;
    unsigned            _numWholeLineChanges;
    unsigned            _offsetForDrawDataPrune;
    NSString            *_lastToolTip;
}
@synthesize foregroundColor = _foregroundColor, backgroundColor = _backgroundColor, specialColor = _specialColor;
@synthesize connection = _connection, actions = _actions;
@synthesize initialWindowLayout = _initialWindowLayout, windowPosition = _windowPosition;
@synthesize waitForAck = _waitForAck, tabBarVisible = _tabBarVisible, imState = _imState;
#ifdef FEAT_BEVAL
@synthesize lastToolTip = _lastToolTip;
#endif

+ (instancetype)shared
{
    static MMBackend *singleton = nil;
    return singleton ?: (singleton = MMBackend.new);
}

- (instancetype)init
{
    if (!(self = [super init])) return nil;

    _outputQueue = NSMutableArray.new;
    _inputQueue = NSMutableArray.new;
    _drawData = [[NSMutableData alloc] initWithCapacity:1024];
    _connections = NSMutableDictionary.new;
    _clients = NSMutableDictionary.new;
    _serverReplyDict = NSMutableDictionary.new;

    NSBundle *bundle = NSBundle.mainBundle;
    NSString *path = [bundle pathForResource:@"Colors" ofType:@"plist"];
    if (path) _colors = [NSDictionary dictionaryWithContentsOfFile:path];

    path = [bundle pathForResource:@"SystemColors" ofType:@"plist"];
    if (path) _systemColors = [NSDictionary dictionaryWithContentsOfFile:path];

    path = [bundle pathForResource:@"Actions" ofType:@"plist"];
    if (path) _actions = [NSDictionary dictionaryWithContentsOfFile:path];

    if (!(_colors && _systemColors && _actions)) {
        ASLogNotice(@"Failed to load dictionaries.%@", MMSymlinkWarningString);
    }

    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];

    gui_mch_free_font(_oldWideFont);
    _oldWideFont = NOFONT;
}

- (void)setBackgroundColor:(unsigned)color
{
    _backgroundColor = MM_COLOR_WITH_TRANSP(color, p_transp);
}

- (void)setForegroundColor:(unsigned)color
{
    _foregroundColor = MM_COLOR(color);
}

- (void)setSpecialColor:(unsigned)color
{
    _specialColor = MM_COLOR(color);
}

- (void)setDefaultColorsBackground:(unsigned)bg foreground:(unsigned)fg
{
    _defaultBackgroundColor = MM_COLOR_WITH_TRANSP(bg, p_transp);
    _defaultForegroundColor = MM_COLOR(fg);

    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&_defaultBackgroundColor length:sizeof(_defaultBackgroundColor)];
    [data appendBytes:&_defaultForegroundColor length:sizeof(_defaultForegroundColor)];
    [self queueMessage:SetDefaultColorsMsgID data:data];
}

- (NSConnection *)connection
{
    if (!_connection) {
        // NOTE!  If the name of the connection changes here it must also be
        // updated in MMAppController.m.
        NSString *name = [NSString stringWithFormat:@"%@-connection", NSBundle.mainBundle.bundlePath];
        _connection = [NSConnection connectionWithRegisteredName:name host:nil];
    }

    // NOTE: '_connection' may be nil here.
    return _connection;
}

- (void)setWindowPosition:(MMPoint)point
{
    ASLogDebug(@"x=%d y=%d", point.col, point.row);
    // NOTE: Setting the window position has no immediate effect on the cached
    // variables _windowPosition.  These are set by the frontend when the
    // window actually moves (see SetWindowPositionMsgID).
    const int pos[] = {_windowPosition.col, _windowPosition.row};
    NSData *data = [NSData dataWithBytes:pos length:sizeof(pos)];
    [self queueMessage:SetWindowPositionMsgID data:data];
}

- (void)queueMessage:(int)msgid properties:(NSDictionary *)props
{
    [self queueMessage:msgid data:[props dictionaryAsData]];
}

- (BOOL)checkin
{
    if (!self.connection) {
        if (_waitForAck) {
            // This is a preloaded process and as such should not cause the
            // MacVim to be opened.  We probably got here as a result of the
            // user quitting MacVim while the process was preloading, so exit
            // this process too.
            // (Don't use mch_exit() since it assumes the process has properly
            // started.)
            exit(0);
        }

        NSBundle *mainBundle = NSBundle.mainBundle;
#if 0
        OSStatus status;
        FSRef ref;

        // Launch MacVim using Launch Services (NSWorkspace would be nicer, but
        // the API to pass Apple Event parameters is broken on 10.4).
        NSString *path = [mainBundle bundlePath];
        status = FSPathMakeRef((const UInt8 *)[path UTF8String], &ref, NULL);
        if (noErr == status) {
            // Pass parameter to the 'Open' Apple Event that tells MacVim not
            // to open an untitled window.
            NSAppleEventDescriptor *desc =
                    [NSAppleEventDescriptor recordDescriptor];
            [desc setParamDescriptor:
                    [NSAppleEventDescriptor descriptorWithBoolean:NO]
                          forKeyword:keyMMUntitledWindow];

            LSLaunchFSRefSpec spec = { &ref, 0, NULL, [desc aeDesc],
                    kLSLaunchDefaults, NULL };
            status = LSOpenFromRefSpec(&spec, NULL);
        }

        if (noErr != status) {
        ASLogCrit(@"Failed to launch MacVim (path=%@).%@",
                  path, MMSymlinkWarningString);
            return NO;
        }
#else
        // Launch MacVim using NSTask.  For some reason the above code using
        // Launch Services sometimes fails on LSOpenFromRefSpec() (when it
        // fails, the dock icon starts bouncing and never stops).  It seems
        // like rebuilding the Launch Services database takes care of this
        // problem, but the NSTask way seems more stable so stick with it.
        //
        // NOTE!  Using NSTask to launch the GUI has the negative side-effect
        // that the GUI won't be activated (or raised) so there is a hack in
        // MMAppController which raises the app when a new window is opened.
        NSArray *args = @[@"yes", [NSString stringWithFormat:@"-%@", MMNoWindowKey]];
        NSString *exeName = mainBundle.infoDictionary[@"CFBundleExecutable"];
        NSString *path = [mainBundle pathForAuxiliaryExecutable:exeName];
        if (!path) {
            ASLogCrit(@"Could not find MacVim executable in bundle.%@", MMSymlinkWarningString);
            return NO;
        }
        [NSTask launchedTaskWithLaunchPath:path arguments:args];
#endif
        // HACK!  Poll the mach bootstrap server until it returns a valid
        // connection to detect that MacVim has finished launching.  Also set a
        // time-out date so that we don't get stuck doing this forever.
        NSDate *to = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!self.connection && NSOrderedDescending == [to compare:NSDate.date])
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.1]];

        if (!self.connection) {
            ASLogCrit(@"Timed-out waiting for GUI to launch.");
            return NO;
        }
    }

    @try {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(connectionDidDie:) name:NSConnectionDidDieNotification object:self.connection];

        _appProxy = self.connection.rootProxy;
        [_appProxy setProtocolForProxy:@protocol(MMAppProtocol)];

        // NOTE: We do not set any new timeout values for the connection to the
        // frontend.  This means that if the frontend is "stuck" (e.g. in a
        // modal loop) then any calls to the frontend will block indefinitely
        // (the default timeouts are huge).
        _identifier = [_appProxy connectBackend:self pid:NSProcessInfo.processInfo.processIdentifier];
        return YES;
    } @catch (NSException *e) {
        ASLogDebug(@"Connect backend failed: reason=%@", e);
    }

    return NO;
}

- (BOOL)openGUIWindow
{
    if (gui_win_x != -1 && gui_win_y != -1) {
        // NOTE: the gui_win_* coordinates are both set to -1 if no :winpos
        // command is in .[g]vimrc.  (This way of detecting if :winpos has been
        // used may cause problems if a second monitor is located to the left
        // and underneath the main monitor as it will have negative
        // coordinates.  However, this seems like a minor problem that is not
        // worth fixing since all GUIs work this way.)
        ASLogDebug(@"default x=%d y=%d", gui_win_x, gui_win_y);
        const int pos[] = {gui_win_x, gui_win_y};
        NSData *data = [NSData dataWithBytes:pos length:sizeof(pos)];
        [self queueMessage:SetWindowPositionMsgID data:data];
    }

    [self queueMessage:OpenWindowMsgID data:nil];

    // HACK: Clear window immediately upon opening to avoid it flashing white.
    [self clearAll];

    return YES;
}

- (void)clearAll
{
    const int type = ClearAllDrawType;

    // Any draw commands in queue are effectively obsolete since this clearAll
    // will negate any effect they have, therefore we may as well clear the
    // draw queue.
    [self clearDrawData];

    [_drawData appendBytes:&type length:sizeof(int)];
}

- (void)clearBlockFromRow:(int)row1 column:(int)col1 toRow:(int)row2 column:(int)col2
{
    const int type = ClearBlockDrawType;

    [_drawData appendBytes:&type length:sizeof(int)];

    [_drawData appendBytes:&_defaultBackgroundColor length:sizeof(_defaultBackgroundColor)];
    [_drawData appendBytes:&row1 length:sizeof(int)];
    [_drawData appendBytes:&col1 length:sizeof(int)];
    [_drawData appendBytes:&row2 length:sizeof(int)];
    [_drawData appendBytes:&col2 length:sizeof(int)];
}

- (void)deleteLinesFromRow:(int)row count:(int)count scrollBottom:(int)bottom left:(int)left right:(int)right
{
    const int type = DeleteLinesDrawType;

    [_drawData appendBytes:&type length:sizeof(int)];

    [_drawData appendBytes:&_defaultBackgroundColor length:sizeof(_defaultBackgroundColor)];
    [_drawData appendBytes:&row length:sizeof(int)];
    [_drawData appendBytes:&count length:sizeof(int)];
    [_drawData appendBytes:&bottom length:sizeof(int)];
    [_drawData appendBytes:&left length:sizeof(int)];
    [_drawData appendBytes:&right length:sizeof(int)];

    if (left == 0 && right == gui.num_cols - 1)
        [self didChangeWholeLine];
}

- (void)drawString:(char_u*)s length:(int)len row:(int)row column:(int)col cells:(int)cells flags:(int)flags
{
    if (len <= 0) return;

    const int type = DrawStringDrawType;

    [_drawData appendBytes:&type length:sizeof(type)];
    [_drawData appendBytes:&_backgroundColor length:sizeof(_backgroundColor)];
    [_drawData appendBytes:&_foregroundColor length:sizeof(_foregroundColor)];
    [_drawData appendBytes:&_specialColor length:sizeof(_specialColor)];
    [_drawData appendBytes:&row length:sizeof(int)];
    [_drawData appendBytes:&col length:sizeof(int)];
    [_drawData appendBytes:&cells length:sizeof(int)];
    [_drawData appendBytes:&flags length:sizeof(int)];
    [_drawData appendBytes:&len length:sizeof(int)];
    [_drawData appendBytes:s length:len];
}

- (void)insertLinesFromRow:(int)row count:(int)count scrollBottom:(int)bottom left:(int)left right:(int)right
{
    const int type = InsertLinesDrawType;

    [_drawData appendBytes:&type length:sizeof(int)];

    [_drawData appendBytes:&_defaultBackgroundColor length:sizeof(_defaultBackgroundColor)];
    [_drawData appendBytes:&row length:sizeof(int)];
    [_drawData appendBytes:&count length:sizeof(int)];
    [_drawData appendBytes:&bottom length:sizeof(int)];
    [_drawData appendBytes:&left length:sizeof(int)];
    [_drawData appendBytes:&right length:sizeof(int)];

    if (left == 0 && right == gui.num_cols-1)
        [self didChangeWholeLine];
}

- (void)drawCursorAtRow:(int)row column:(int)col shape:(int)shape fraction:(int)percent color:(int)color
{
    const int type = DrawCursorDrawType;
    const unsigned uc = MM_COLOR(color);

    [_drawData appendBytes:&type length:sizeof(int)];

    [_drawData appendBytes:&uc length:sizeof(unsigned)];
    [_drawData appendBytes:&row length:sizeof(int)];
    [_drawData appendBytes:&col length:sizeof(int)];
    [_drawData appendBytes:&shape length:sizeof(int)];
    [_drawData appendBytes:&percent length:sizeof(int)];
}

- (void)drawInvertedRectAtRow:(int)row column:(int)col numRows:(int)nr numColumns:(int)nc invert:(int)invert
{
    const int type = DrawInvertedRectDrawType;
    [_drawData appendBytes:&type length:sizeof(int)];

    [_drawData appendBytes:&row length:sizeof(int)];
    [_drawData appendBytes:&col length:sizeof(int)];
    [_drawData appendBytes:&nr length:sizeof(int)];
    [_drawData appendBytes:&nc length:sizeof(int)];
    [_drawData appendBytes:&invert length:sizeof(int)];
}

- (void)drawSign:(NSString *)name atRow:(int)row column:(int)col width:(int)width height:(int)height
{
    const int type = DrawSignDrawType;
    [_drawData appendBytes:&type length:sizeof(int)];

    [_drawData appendBytes:&col length:sizeof(int)];
    [_drawData appendBytes:&row length:sizeof(int)];
    [_drawData appendBytes:&width length:sizeof(int)];
    [_drawData appendBytes:&height length:sizeof(int)];

    const char* u8 = name.UTF8String;
    const int length = (int)strlen(u8) + 1;
    [_drawData appendBytes:&length length:sizeof(int)];
    [_drawData appendBytes:u8 length:length];
}

- (void)update
{
    // Keep running the run-loop until there is no more input to process.
    while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true) == kCFRunLoopRunHandledSource) {}
}

- (void)flushQueue:(BOOL)force
{
    // NOTE: This variable allows for better control over when the queue is
    // flushed.  It can be set to YES at the beginning of a sequence of calls
    // that may potentially add items to the queue, and then restored back to
    // NO.
    if (_flushDisabled) return;

    if (_drawData.length > 0) {
        // HACK!  Detect changes to 'guifontwide'.
        if (gui.wide_font != _oldWideFont) {
            gui_mch_free_font(_oldWideFont);
            _oldWideFont = gui_mch_retain_font(gui.wide_font);
            [self setFont:_oldWideFont wide:YES];
        }

        int type = SetCursorPosDrawType;
        [_drawData appendBytes:&type length:sizeof(type)];
        [_drawData appendBytes:&gui.row length:sizeof(gui.row)];
        [_drawData appendBytes:&gui.col length:sizeof(gui.col)];

        [self queueMessage:BatchDrawMsgID data:_drawData.copy];
        [self clearDrawData];
    }

    if (_outputQueue.count != 0) {
        [self insertVimStateMessage];

        @try {
            ASLogDebug(@"Flushing queue: %@", debugStringForMessageQueue(_outputQueue));
            [_appProxy processInput:_outputQueue forIdentifier:_identifier];
        } @catch (NSException *e) {
            ASLogDebug(@"processInput:forIdentifer failed: reason=%@", e);
            if (!self.connection.isValid) {
                ASLogDebug(@"Connection is invalid, exit now!");
                ASLogDebug(@"waitForAck=%d got_int=%d", _waitForAck, got_int);
                mch_exit(-1);
            }
        }
        [_outputQueue removeAllObjects];
    }
}

- (BOOL)waitForInput:(int)milliseconds
{
    // Return NO if we timed out waiting for input, otherwise return YES.
    BOOL inputReceived = NO;

    // Only start the run loop if the input queue is empty, otherwise process
    // the input first so that the input on queue isn't delayed.
    if (_inputQueue.count || input_available() || got_int) {
        inputReceived = YES;
    } else {
        const BOOL needsWait = milliseconds >= 0;

        // Wait for the specified amount of time, unless 'milliseconds' is
        // negative in which case we wait "forever" (1e6 seconds translates to
        // approximately 11 days).
        CFTimeInterval dt = (needsWait ? .001 * milliseconds : 1e6);
        NSTimer *timer = nil;

        // Set interval timer which checks for the events of job and channel
        // when there is any pending job or channel.
        if (dt > 0.1 && (has_any_channel() || has_pending_job())) {
            timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(checkForProcessEvents:) userInfo:nil repeats:YES];
            [NSRunLoop.currentRunLoop addTimer:timer forMode:NSDefaultRunLoopMode];
        }

        while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, dt, true) == kCFRunLoopRunHandledSource) {
            // In order to ensure that all input on the run-loop has been
            // processed we set the timeout to 0 and keep processing until the
            // run-loop times out.
            dt = 0.0;
            if (_inputQueue.count || input_available() || got_int) {
                inputReceived = YES;
            }
        }

        if (_inputQueue.count || input_available() || got_int)
            inputReceived = YES;

        [timer invalidate];
    }

    // The above calls may have placed messages on the input queue so process
    // it now.  This call may enter a blocking loop.
    if (_inputQueue.count != 0) [self processInputQueue];

    return inputReceived;
}

- (void)exit
{
    // NOTE: This is called if mch_exit() is called.  Since we assume here that
    // the process has started properly, be sure to use exit() instead of
    // mch_exit() to prematurely terminate a process (or set '_teminating'
    // first).

    // Make sure no connectionDidDie: notification is received now that we are
    // already exiting.
    [NSNotificationCenter.defaultCenter removeObserver:self];

    // The '_teminating' flag indicates that the frontend is also exiting so
    // there is no need to flush any more output since the frontend won't look
    // at it anyway.
    if (!_teminating && self.connection.isValid) {
        @try {
            // Flush the entire queue in case a VimLeave autocommand added
            // something to the queue.
            [self queueMessage:CloseWindowMsgID data:nil];
            ASLogDebug(@"Flush output queue before exit: %@", debugStringForMessageQueue(_outputQueue));
            [_appProxy processInput:_outputQueue forIdentifier:_identifier];
        } @catch (NSException *e) {
            ASLogDebug(@"CloseWindowMsgID send failed: reason=%@", e);
        }

        // NOTE: If Cmd-w was pressed to close the window the menu is briefly
        // highlighted and during this pause the frontend won't receive any DO
        // messages.  If the Vim process exits before this highlighting has
        // finished Cocoa will emit the following error message:
        //   *** -[NSMachPort handlePortMessage:]: dropping incoming DO message
        //   because the connection or ports are invalid
        // To avoid this warning we delay here.  If the warning still appears
        // this delay may need to be increased.
        usleep(150000);
    }

#ifdef MAC_CLIENTSERVER
    // The default connection is used for the client/server code.
    if (_vimServerConnection) {
        _vimServerConnection.rootObject = nil;
        [_vimServerConnection invalidate];
    }
#endif
}

- (void)selectTab:(int)index
{
    index -= 1;
    NSData *data = [NSData dataWithBytes:&index length:sizeof(int)];
    [self queueMessage:SelectTabMsgID data:data];
}

- (void)updateTabBar
{
    NSMutableData *data = NSMutableData.new;

    int idx = tabpage_index(curtab) - 1;
    [data appendBytes:&idx length:sizeof(int)];

    for (tabpage_T *tp = first_tabpage; tp; tp = tp->tp_next) {
        const int count = MMTabInfoCount;
        [data appendBytes:&count length:sizeof(int)];
        for (int i = MMTabLabel; i < count; ++i) {
            // This function puts the label of the tab in the global 'NameBuff'.
            get_tabline_label(tp, i == MMTabToolTip);
            NSString *label = [NSString stringWithVimString:NameBuff];
            const int length = [label lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [data appendBytes:&length length:sizeof(int)];
            if (length > 0) [data appendBytes:label.UTF8String length:length];
        }
    }

    [self queueMessage:UpdateTabBarMsgID data:data];
}

- (void)showTabBar:(BOOL)enable
{
    _tabBarVisible = enable;

    const int msgid = enable ? ShowTabBarMsgID : HideTabBarMsgID;
    [self queueMessage:msgid data:nil];
}

- (void)setRows:(int)rows columns:(int)cols
{
    const int dim[] = {rows, cols};
    NSData *data = [NSData dataWithBytes:&dim length:sizeof(dim)];

    [self queueMessage:SetTextDimensionsMsgID data:data];
}

- (void)resizeView
{
    [self queueMessage:ResizeViewMsgID data:nil];
}

- (void)setWindowTitle:(char *)title
{
    NSMutableData *data = NSMutableData.new;
    const int length = strlen(title);
    if (length <= 0) return;

    [data appendBytes:&length length:sizeof(int)];
    [data appendBytes:title length:length];

    [self queueMessage:SetWindowTitleMsgID data:data];
}

- (void)setDocumentFilename:(char *)filename
{
    NSMutableData *data = NSMutableData.new;
    const int length = filename ? strlen(filename) : 0;

    [data appendBytes:&length length:sizeof(int)];
    if (length > 0) [data appendBytes:filename length:length];

    [self queueMessage:SetDocumentFilenameMsgID data:data];
}

- (char *)browseForFileWithAttributes:(NSDictionary *)attr
{
    char_u *cstring = NULL;

    [self queueMessage:BrowseForFileMsgID properties:attr];
    [self flushQueue:YES];

    @try {
        [self waitForDialogReturn];

        if ([_dialogReturn isKindOfClass:NSString.class]) {
            NSString *string = (NSString *)_dialogReturn;
            cstring = string.vimStringSave;
        }

        _dialogReturn = nil;
    } @catch (NSException *e) {
        ASLogDebug(@"Exception: reason=%@", e);
    }

    return (char *)cstring;
}

- (oneway void)setDialogReturn:(in bycopy id)obj
{
    ASLogDebug(@"%@", obj);

    // NOTE: This is called by
    //   - [MMVimController panelDidEnd:::], and
    //   - [MMVimController alertDidEnd:::],
    // to indicate that a save/open panel or alert has finished.

    // We want to distinguish between "no dialog return yet" and "dialog
    // returned nothing".  The former can be tested with _dialogReturn == nil,
    // the latter with _dialogReturn == [NSNull null].
    if (!obj) obj = NSNull.null;

    if (obj != _dialogReturn) _dialogReturn = obj;
}

- (int)showDialogWithAttributes:(NSDictionary *)attr textField:(char *)txtfield
{
    int retval = 0;

    [self queueMessage:ShowDialogMsgID properties:attr];
    [self flushQueue:YES];

    @try {
        [self waitForDialogReturn];

        if ([_dialogReturn isKindOfClass:NSArray.class] && [_dialogReturn count] != 0) {
            NSArray *dialogReturn = (NSArray *)_dialogReturn;
            retval = [dialogReturn.firstObject intValue];
            if (txtfield && dialogReturn.count > 1) {
                NSString *string = dialogReturn[1];
                char_u *ret = (char_u *)string.UTF8String;
#ifdef FEAT_MBYTE
                ret = CONVERT_FROM_UTF8(ret);
#endif
                vim_strncpy((char_u*)txtfield, ret, IOSIZE - 1);
#ifdef FEAT_MBYTE
                CONVERT_FROM_UTF8_FREE(ret);
#endif
            }
        }

        _dialogReturn = nil;
    } @catch (NSException *e) {
        ASLogDebug(@"Exception: reason=%@", e);
    }

    return retval;
}

- (void)showToolbar:(int)enable flags:(int)flags
{
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&enable length:sizeof(int)];
    [data appendBytes:&flags length:sizeof(int)];

    [self queueMessage:ShowToolbarMsgID data:data];
}

- (void)createScrollbarWithIdentifier:(int32_t)ident type:(int)type
{
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&ident length:sizeof(int32_t)];
    [data appendBytes:&type length:sizeof(int)];

    [self queueMessage:CreateScrollbarMsgID data:data];
}

- (void)destroyScrollbarWithIdentifier:(int32_t)ident
{
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&ident length:sizeof(int32_t)];

    [self queueMessage:DestroyScrollbarMsgID data:data];
}

- (void)showScrollbarWithIdentifier:(int32_t)ident state:(int)visible
{
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&ident length:sizeof(int32_t)];
    [data appendBytes:&visible length:sizeof(int)];

    [self queueMessage:ShowScrollbarMsgID data:data];
}

- (void)setScrollbarPosition:(int)pos length:(int)len identifier:(int32_t)ident
{
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&ident length:sizeof(int32_t)];
    [data appendBytes:&pos length:sizeof(int)];
    [data appendBytes:&len length:sizeof(int)];

    [self queueMessage:SetScrollbarPositionMsgID data:data];
}

- (void)setScrollbarThumbValue:(long)val size:(long)size max:(long)max identifier:(int32_t)ident
{
    const float fval = MIN(MAX(max - size + 1 > 0 ? (float)val / (max - size + 1) : 0, 0), 1);
    const float prop = MIN(MAX((float)size / (max + 1), 0), 1);

    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&ident length:sizeof(int32_t)];
    [data appendBytes:&fval length:sizeof(float)];
    [data appendBytes:&prop length:sizeof(float)];

    [self queueMessage:SetScrollbarThumbMsgID data:data];
}

- (void)setFont:(GuiFont)font wide:(BOOL)wide
{
    NSString *fontName = (__bridge NSString *)font;
    float size = 0;
    NSArray *components = [fontName componentsSeparatedByString:@":h"];
    if (components.count == 2) {
        size = [components.lastObject floatValue];
        fontName = components.firstObject;
    }

    const int length = [fontName lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&size length:sizeof(float)];
    [data appendBytes:&length length:sizeof(int)];

    if (length > 0)
        [data appendBytes:fontName.UTF8String length:length];
    else if (!wide)
        return;     // Only the wide font can be set to nothing

    [self queueMessage:(wide ? SetWideFontMsgID : SetFontMsgID) data:data];
}

- (void)executeActionWithName:(NSString *)name
{
    const int length = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    if (length > 0) {
        NSMutableData *data = NSMutableData.new;

        [data appendBytes:&length length:sizeof(int)];
        [data appendBytes:name.UTF8String length:length];

        [self queueMessage:ExecuteActionMsgID data:data];
    }
}

- (void)setMouseShape:(int)shape
{
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&shape length:sizeof(int)];
    [self queueMessage:SetMouseShapeMsgID data:data];
}

- (void)setBlinkWait:(int)wait on:(int)on off:(int)off
{
#if 0
    // Vim specifies times in milliseconds, whereas Cocoa wants them in
    // seconds.
    _blinkWaitInterval = .001 * wait;
    _blinkOnInterval = .001 * on;
    _blinkOffInterval = .001 * off;
#endif
}

- (void)startBlink
{
#if 0
    if (_blinkTimer) {
        [_blinkTimer invalidate];
        _blinkTimer = nil;
    }

    if (_blinkWaitInterval > 0 && _blinkOnInterval > 0 && _blinkOffInterval > 0 && gui.in_focus) {
        _blinkState = MMBlinkStateOn;
        _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:_blinkWaitInterval target:self selector:@selector(blinkTimerFired:) userInfo:nil repeats:NO];
        gui_update_cursor(TRUE, FALSE);
        [self flushQueue:YES];
    }
#endif
}

- (void)stopBlink:(BOOL)updateCursor
{
#if 0
    if (MMBlinkStateOff == _blinkState && updateCursor) {
        gui_update_cursor(TRUE, FALSE);
        [self flushQueue:YES];
    }

    _blinkState = MMBlinkStateNone;
#endif
}

- (void)adjustLinespace:(int)linespace
{
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&linespace length:sizeof(int)];
    [self queueMessage:AdjustLinespaceMsgID data:data];
}

- (void)adjustColumnspace:(int)columnspace
{
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&columnspace length:sizeof(int)];
    [self queueMessage:AdjustColumnspaceMsgID data:data];
}

- (void)activate
{
    [self queueMessage:ActivateMsgID data:nil];
}

- (void)setPreEditRow:(int)row column:(int)col
{
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];
    [self queueMessage:SetPreEditPositionMsgID data:data];
}

- (int)lookupColorWithKey:(NSString *)key
{
    if (key.length == 0) return INVALCOLOR;

    NSString *stripKey = [[[key.lowercaseString
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByString:@" "]
               componentsJoinedByString:@""];

    if (stripKey && stripKey.length != 0) {
        // First of all try to lookup key in the color dictionary; note that
        // all keys in this dictionary are lowercase with no whitespace.
        id obj = _colors[stripKey];
        if (obj) return [obj intValue];

        // The key was not in the dictionary; is it perhaps of the form
        // #rrggbb?
        if (stripKey.length > 1 && [stripKey characterAtIndex:0] == '#') {
            NSScanner *scanner = [NSScanner scannerWithString:stripKey];
            scanner.scanLocation = 1;
            unsigned hex = 0;
            if ([scanner scanHexInt:&hex]) return (int)hex;
        }

        // As a last resort, check if it is one of the system defined colors.
        // The keys in this dictionary are also lowercase with no whitespace.
        if ((obj = _systemColors[stripKey]) != nil) {
            NSColor *col = [NSColor performSelector:NSSelectorFromString(obj)];
            if (col) {
                CGFloat r, g, b, a;
                col = [col colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
                [col getRed:&r green:&g blue:&b alpha:&a];
                return (((int)(r * 255 + .5f) & 0xff) << 16)
                     + (((int)(g * 255 + .5f) & 0xff) << 8)
                     +  ((int)(b * 255 + .5f) & 0xff);
            }
        }
    }

    ASLogNotice(@"No color with key %@ found.", stripKey);
    return INVALCOLOR;
}

- (BOOL)hasSpecialKeyWithValue:(char_u *)value
{
    for (size_t i = 0; specialKeys[i].keysym != 0; i++) {
        if (value[0] == specialKeys[i].code0 && value[1] == specialKeys[i].code1)
            return YES;
    }
    return NO;
}

- (void)enterFullScreen:(int)fuoptions background:(int)bg
{
    NSMutableData *data = NSMutableData.new;
    bg = MM_COLOR(bg);

    [data appendBytes:&fuoptions length:sizeof(int)];
    [data appendBytes:&bg length:sizeof(int)];

    [self queueMessage:EnterFullScreenMsgID data:data];
}

- (void)leaveFullScreen
{
    [self queueMessage:LeaveFullScreenMsgID data:nil];
}

- (void)setFullScreenBackgroundColor:(int)color
{
    NSMutableData *data = NSMutableData.new;
    color = MM_COLOR(color);

    [data appendBytes:&color length:sizeof(int)];

    [self queueMessage:SetFullScreenColorMsgID data:data];
}

- (void)setAntialias:(BOOL)antialias
{
    const int msgid = antialias ? EnableAntialiasMsgID : DisableAntialiasMsgID;

    [self queueMessage:msgid data:nil];
}

- (void)setLigatures:(BOOL)ligatures
{
    const int msgid = ligatures ? EnableLigaturesMsgID : DisableLigaturesMsgID;

    [self queueMessage:msgid data:nil];
}

- (void)setThinStrokes:(BOOL)thinStrokes
{
    const int msgid = thinStrokes ? EnableThinStrokesMsgID : DisableThinStrokesMsgID;

    [self queueMessage:msgid data:nil];
}

- (void)setBlurRadius:(int)radius
{
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&radius length:sizeof(radius)];
    [self queueMessage:SetBlurRadiusMsgID data:data];
}

- (void)updateModifiedFlag
{
    const int state = self.checkForModifiedBuffers;
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&state length:sizeof(state)];
    [self queueMessage:SetBuffersModifiedMsgID data:data];
}

- (oneway void)processInput:(int)msgid data:(in bycopy NSData *)data
{
    //
    // This is a DO method which is called from inside MacVim to add new input
    // to this Vim process.  It may get called when the run loop is updated.
    //
    // NOTE: DO NOT MODIFY VIM STATE IN THIS METHOD! (Adding data to input
    // buffers is OK however.)
    //
    // Add keyboard input to Vim's input buffer immediately.  We have to do
    // this because in many places Vim polls the input buffer whilst waiting
    // for keyboard input (so Vim may lock up forever otherwise).
    //
    // Similarly, TerminateNowMsgID must be checked immediately otherwise code
    // which waits on the run loop will fail to detect this message (e.g. in
    // waitForConnectionAcknowledgement).
    //
    // All other input is processed when processInputQueue is called (typically
    // this happens in waitForInput:).
    //
    // TODO: Process mouse events here as well?  Anything else?
    //

    if (KeyDownMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        unsigned mods = *((unsigned *)bytes);  bytes += sizeof(unsigned);
        const unsigned code = *((unsigned *)bytes);  bytes += sizeof(unsigned);
        const unsigned len  = *((unsigned *)bytes);  bytes += sizeof(unsigned);

        if (ctrl_c_interrupts && 1 == len) {
            // NOTE: the flag ctrl_c_interrupts is 0 e.g. when the user has
            // mappings to something like <C-c>g.  Also it seems the flag
            // intr_char is 0 when MacVim was started from Finder whereas it is
            // 0x03 (= Ctrl_C) when started from Terminal.
            char_u *str = (char_u *)bytes;
            if (str[0] == Ctrl_C || (str[0] == intr_char && intr_char != 0)) {
                ASLogDebug(@"Got INT, str[0]=%#x ctrl_c_interrupts=%d intr_char=%#x", str[0], ctrl_c_interrupts, intr_char);
                got_int = TRUE;
                [_inputQueue removeAllObjects];
                return;
            }
        }

        // The lowest bit of the modifiers is set if this key is a repeat.
        const BOOL isKeyRepeat = (mods & 1) != 0;

        // Ignore key press if the input buffer has something in it and this
        // key is a repeat (since this means Vim can't keep up with the speed
        // with which new input is being received).
        if (!isKeyRepeat || vim_is_input_buf_empty()) {
            NSString *key = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
            mods = EventModifierFlagsToVimModMask(mods);
            [self doKeyDown:key keyCode:code modifiers:mods];
        } else {
            ASLogDebug(@"Dropping repeated keyboard input");
        }
    } else if (SetMarkedTextMsgID == msgid) {
        // NOTE: This message counts as keyboard input...
        [self handleMarkedText:data];
    } else if (TerminateNowMsgID == msgid) {
        // Terminate immediately (the frontend is about to quit or this process
        // was aborted).  Don't preserve modified files since the user would
        // already have been presented with a dialog warning if there were any
        // modified files when we get here.
        _teminating = YES;
        getout(0);
    } else {
        // First remove previous instances of this message from the input
        // queue, else the input queue may fill up as a result of Vim not being
        // able to keep up with the speed at which new messages are received.
        // TODO: Remove all previous instances (there could be many)?
        const int count = _inputQueue.count;
        for (int i = 1; i < count; i += 2) {
            if ([_inputQueue[i - 1] intValue] == msgid) {
                ASLogDebug(@"Input queue filling up, remove message: %s", MessageStrings[msgid]);
                [_inputQueue removeObjectAtIndex:i];
                [_inputQueue removeObjectAtIndex:i - 1];
                break;
            }
        }

        // Now add message to input queue.  Add null data if necessary to
        // ensure that input queue has even length.
        [_inputQueue addObject:@(msgid)];
        [_inputQueue addObject:(data ? (id)data : NSNull.null)];
    }
}

- (id)evaluateExpressionCocoa:(in bycopy NSString *)expr errorString:(out bycopy NSString **)errstr
{
    return evalExprCocoa(expr, errstr);
}

- (NSString *)evaluateExpression:(in bycopy NSString *)expr
{
    NSString *eval = nil;
    char_u *cstring = (char_u*)expr.UTF8String;

#ifdef FEAT_MBYTE
    cstring = CONVERT_FROM_UTF8(cstring);
#endif

    char_u *result = eval_client_expr_to_string(cstring);

#ifdef FEAT_MBYTE
    CONVERT_FROM_UTF8_FREE(cstring);
#endif

    if (result) {
        cstring = result;
#ifdef FEAT_MBYTE
        cstring = CONVERT_TO_UTF8(cstring);
#endif
        eval = [NSString stringWithUTF8String:(char *)cstring];
#ifdef FEAT_MBYTE
        CONVERT_TO_UTF8_FREE(cstring);
#endif
        vim_free(result);
    }

    return eval;
}

- (BOOL)starRegisterToPasteboard:(byref NSPasteboard *)pboard
{
    // TODO: This method should share code with clip_mch_request_selection().

    if (VIsual_active && (State & NORMAL) && clip_star.available) {
        // If there is no pasteboard, return YES to indicate that there is text
        // to copy.
        if (!pboard) return YES;

        // The code below used to be clip_copy_selection() but it is now
        // static, so do it manually.
        clip_update_selection(&clip_star);
        clip_free_selection(&clip_star);
        clip_get_selection(&clip_star);
        clip_gen_set_selection(&clip_star);

        // Get the text to put on the pasteboard.
        long_u llen = 0; char_u *str = 0;
        int type = clip_convert_selection(&str, &llen, &clip_star);
        if (type < 0) return NO;
        
        // TODO: Avoid overflow.
        int len = (int)llen;
#ifdef FEAT_MBYTE
        if (output_conv.vc_type != CONV_NONE) {
            char_u *conv_str = string_convert(&output_conv, str, &len);
            if (conv_str) {
                vim_free(str);
                str = conv_str;
            }
        }
#endif

        NSString *string = [[NSString alloc] initWithBytes:str length:len encoding:NSUTF8StringEncoding];
        NSArray *types = @[NSStringPboardType];
        [pboard declareTypes:types owner:nil];
        const BOOL ok = [pboard setString:string forType:NSStringPboardType];
    
        vim_free(str);

        return ok;
    }

    return NO;
}

- (oneway void)addReply:(in bycopy NSString *)reply server:(in byref id <MMVimServerProtocol>)server
{
    ASLogDebug(@"reply=%@ server=%@", reply, (id)server);

    // Replies might come at any time and in any order so we keep them in an
    // array inside a dictionary with the send port used as key.

    NSConnection *connection = [(NSDistantObject *)server connectionForProxy];
    // HACK! Assume connection uses mach ports.
    const int port = [(NSMachPort *)connection.sendPort machPort];
    NSNumber *key = @(port);

    NSMutableArray *replies = _serverReplyDict[key];
    if (!replies) {
        _serverReplyDict[key] = replies = NSMutableArray.new;
    }

    [replies addObject:reply];
}

- (void)addInput:(in bycopy NSString *)input client:(in byref id <MMVimClientProtocol>)client
{
    ASLogDebug(@"input=%@ client=%@", input, (id)client);

    // NOTE: We don't call addInput: here because it differs from
    // server_to_input_buf() in that it always sets the 'silent' flag and we
    // don't want the MacVim client/server code to behave differently from
    // other platforms.
    char_u *cstring = input.vimStringSave;
    server_to_input_buf(cstring);
    vim_free(cstring);

    [self addClient:(id)client];
}

- (NSString *)evaluateExpression:(in bycopy NSString *)expression client:(in byref id <MMVimClientProtocol>)client
{
    [self addClient:(id)client];
    return [self evaluateExpression:expression];
}

- (void)registerServerWithName:(NSString *)baseName
{
    NSString *name = baseName;

    _vimServerConnection = [[NSConnection alloc] initWithReceivePort:NSPort.port sendPort:nil];

    for (NSUInteger i = 0; i < MMServerMax; ++i) {
        NSString *connName = [self connectionNameFromServerName:name];

        if ([_vimServerConnection registerName:connName]) {
            ASLogInfo(@"Registered server with name: %@", name);

            // TODO: Set request/reply time-outs to something else?
            //
            // Don't wait for requests (time-out means that the message is
            // dropped).
            _vimServerConnection.requestTimeout = 0;
            //_vimServerConnection.replyTimeout = MMReplyTimeout;
            _vimServerConnection.rootObject = self;

            // NOTE: 'serverName' is a global variable
            serverName = name.vimStringSave;
#ifdef FEAT_EVAL
            set_vim_var_string(VV_SEND_SERVER, serverName, -1);
#endif
#ifdef FEAT_TITLE
            need_maketitle = TRUE;
#endif
            NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
            [self queueMessage:SetServerNameMsgID data:data];
            break;
        }

        name = [NSString stringWithFormat:@"%@%d", baseName, (int)i + 1];
    }
}

- (BOOL)sendToServer:(NSString *)name string:(NSString *)string reply:(char_u **)reply port:(int *)port expression:(BOOL)expr silent:(BOOL)silent
{
    // NOTE: If 'name' equals 'serverName' then the request is local (client
    // and server are the same).  This case is not handled separately, so a
    // connection will be set up anyway (this simplifies the code).

    NSConnection *connection = [self connectionForServerName:name];
    if (!connection) {
        if (!silent) {
            char_u *cstring = (char_u *)name.UTF8String;
#ifdef FEAT_MBYTE
            cstring = CONVERT_FROM_UTF8(cstring);
#endif
            EMSG2(_(e_noserver), cstring);
#ifdef FEAT_MBYTE
            CONVERT_FROM_UTF8_FREE(cstring);
#endif
        }
        return NO;
    }

    if (port) {
        // HACK! Assume connection uses mach ports.
        *port = [(NSMachPort *)connection.sendPort machPort];
    }

    id proxy = connection.rootProxy;
    [proxy setProtocolForProxy:@protocol(MMVimServerProtocol)];

    @try {
        if (expr) {
            NSString *eval = [proxy evaluateExpression:string client:self];
            if (reply) {
                if (eval) {
                    *reply = eval.vimStringSave;
                } else {
                    *reply = vim_strsave((char_u*)_(e_invexprmsg));
                }
            }

            if (!eval) return NO;
        } else {
            [proxy addInput:string client:self];
        }
    } @catch (NSException *e) {
        ASLogDebug(@"Exception: reason=%@", e);
        return NO;
    }

    return YES;
}

- (NSArray *)serverList
{
    NSArray *list = nil;

    if (self.connection) {
        id proxy = self.connection.rootProxy;
        [proxy setProtocolForProxy:@protocol(MMAppProtocol)];

        @try {
            list = [proxy serverList];
        } @catch (NSException *e) {
            ASLogDebug(@"serverList failed: reason=%@", e);
        }
    } else {
        // We get here if a --remote flag is used before MacVim has started.
        ASLogInfo(@"No connection to MacVim, server listing not possible.");
    }

    return list;
}

- (NSString *)peekForReplyOnPort:(int)port
{
    ASLogDebug(@"port=%d", port);

    NSNumber *key = [NSNumber numberWithInt:port];
    NSMutableArray *replies = [_serverReplyDict objectForKey:key];
    if (replies && [replies count]) {
        ASLogDebug(@"    %ld replies, topmost is: %@", [replies count],
                   [replies objectAtIndex:0]);
        return [replies objectAtIndex:0];
    }

    ASLogDebug(@"    No replies");
    return nil;
}

- (NSString *)waitForReplyOnPort:(int)port
{
    ASLogDebug(@"port=%d", port);
    
    NSConnection *conn = [self connectionForServerPort:port];
    if (!conn)
        return nil;

    NSNumber *key = [NSNumber numberWithInt:port];
    NSMutableArray *replies = nil;
    NSString *reply = nil;

    // Wait for reply as long as the connection to the server is valid (unless
    // user interrupts wait with Ctrl-C).
    while (!got_int && [conn isValid] &&
            !(replies = [_serverReplyDict objectForKey:key])) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
    }

    if (replies) {
        if ([replies count] > 0) {
            reply = [replies objectAtIndex:0];
            ASLogDebug(@"    Got reply: %@", reply);
            [replies removeObjectAtIndex:0];
        }

        if ([replies count] == 0)
            [_serverReplyDict removeObjectForKey:key];
    }

    return reply;
}

- (BOOL)sendReply:(NSString *)reply toPort:(int)port
{
    id client = _clients[@(port)];
    if (client) {
        @try {
            ASLogDebug(@"reply=%@ port=%d", reply, port);
            [client addReply:reply server:self];
            return YES;
        } @catch (NSException *e) {
            ASLogDebug(@"addReply:server: failed: reason=%@", e);
        }
    } else {
        ASLogNotice(@"server2client failed; no client with id %d", port);
    }

    return NO;
}

- (void)waitForConnectionAcknowledgement
{
    if (!_waitForAck) return;

    while (_waitForAck && !got_int && self.connection.isValid) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
        ASLogDebug(@"  waitForAck=%d got_int=%d isValid=%d", _waitForAck, got_int, self.connection.isValid);
    }

    if (_waitForAck) {
        ASLogDebug(@"Never received a connection acknowledgement");
        [NSNotificationCenter.defaultCenter removeObserver:self];
        _appProxy = nil;

        // NOTE: We intentionally do not call mch_exit() since this in turn
        // will lead to -[MMBackend exit] getting called which we want to
        // avoid.
        exit(0);
    }

    ASLogInfo(@"Connection acknowledgement received");
    [self processInputQueue];
}

- (oneway void)acknowledgeConnection
{
    ASLogDebug(@"");
    _waitForAck = NO;
}

- (void)setImState:(BOOL)activated
{
    if (_imState != activated) {
        _imState = activated;
        gui_update_cursor(TRUE, FALSE);
        [self flushQueue:YES];
    }
}

#ifdef FEAT_BEVAL
- (void)setLastToolTip:(NSString *)toolTip
{
    if (toolTip != _lastToolTip) {
        _lastToolTip = toolTip.copy;
    }
}
#endif

- (void)addToMRU:(NSArray *)filenames
{
    [self queueMessage:AddToMRUMsgID properties:@{@"filenames": filenames}];
}

@end // MMBackend



@implementation MMBackend (Private)

- (void)clearDrawData
{
    _drawData.length = 0;
    _numWholeLineChanges = _offsetForDrawDataPrune = 0;
}

- (void)didChangeWholeLine
{
    // It may happen that draw queue is filled up with lots of changes that
    // affect a whole row.  If the number of such changes equals twice the
    // number of visible rows then we can prune some commands off the queue.
    //
    // NOTE: If we don't perform this pruning the draw queue may grow
    // indefinitely if Vim were to repeatedly send draw commands without ever
    // waiting for new input (that's when the draw queue is flushed).  The one
    // instance I know where this can happen is when a command is executed in
    // the shell (think ":grep" with thousands of matches).

    ++_numWholeLineChanges;
    if (_numWholeLineChanges == gui.num_rows) {
        // Remember the offset to prune up to.
        _offsetForDrawDataPrune = _drawData.length;
    } else if (_numWholeLineChanges == 2*gui.num_rows) {
        // Delete all the unnecessary draw commands.
        NSMutableData *d = [[NSMutableData alloc] initWithBytes:_drawData.bytes + _offsetForDrawDataPrune length:_drawData.length - _offsetForDrawDataPrune];
        _offsetForDrawDataPrune = d.length;
        _numWholeLineChanges -= gui.num_rows;
        _drawData = d;
    }
}

- (void)waitForDialogReturn
{
    // Keep processing the run loop until a dialog returns.  To avoid getting
    // stuck in an endless loop (could happen if the setDialogReturn: message
    // was lost) we also do some paranoia checks.
    //
    // Note that in Cocoa the user can still resize windows and select menu
    // items while a sheet is being displayed, so we can't just wait for the
    // first message to arrive and assume that is the setDialogReturn: call.

    while (!_dialogReturn && !got_int && self.connection.isValid)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];

    // Search for any resize messages on the input queue.  All other messages
    // on the input queue are dropped.  The reason why we single out resize
    // messages is because the user may have resized the window while a sheet
    // was open.
    const int count = _inputQueue.count;
    if (count != 0) {
        id textDimData = nil;
        if (count % 2 == 0) {
            for (int i = count - 2; i >= 0; i -= 2) {
                int msgid = [_inputQueue[i] intValue];
                if (SetTextDimensionsMsgID == msgid) {
                    textDimData = _inputQueue[i + 1];
                    break;
                }
            }
        }
        [_inputQueue removeAllObjects];
        if (textDimData) {
            [_inputQueue addObject:@(SetTextDimensionsMsgID)];
            [_inputQueue addObject:textDimData];
        }
    }
}

- (void)insertVimStateMessage
{
    // NOTE: This is the place to add Vim state that needs to be accessed from
    // MacVim.  Do not add state that could potentially require lots of memory
    // since this message gets sent each time the output queue is forcibly
    // flushed (e.g. storing the currently selected text would be a bad idea).
    // We take this approach of "pushing" the state to MacVim to avoid having
    // to make synchronous calls from MacVim to Vim in order to get state.

    NSDictionary *vimState = @{
        @"pwd": NSFileManager.defaultManager.currentDirectoryPath,
        @"p_mh": @(p_mh),
        @"p_mmta": @(curbuf ? curbuf->b_p_mmta : NO), 
        @"numTabs": @(MAX(tabpage_index(NULL) - 1, 0)), 
        @"fullScreenOptions": @(fuoptions_flags), 
        @"p_mouset": @(p_mouset), 
    };

    // Put the state before all other messages.
    // TODO: If called multiple times the oldest state will be used! Should
    // remove any current Vim state messages from the queue first.
    int msgid = SetVimStateMsgID;
    [_outputQueue insertObject:[vimState dictionaryAsData] atIndex:0];
    [_outputQueue insertObject:[NSData dataWithBytes:&msgid length:sizeof(int)] atIndex:0];
}

- (void)processInputQueue
{
    if (_inputQueue.count == 0) return;

    // NOTE: One of the input events may cause this method to be called
    // recursively, so copy the input queue to a local variable and clear the
    // queue before starting to process input events (otherwise we could get
    // stuck in an endless loop).
    NSArray *q = _inputQueue.copy;
    unsigned i, count = q.count;

    [_inputQueue removeAllObjects];

    for (i = 1; i < count; i+=2) {
        int msgid = [q[i - 1] intValue];
        id data = q[i];
        if ([data isEqual:NSNull.null]) data = nil;

        ASLogDebug(@"(%d) %s", i, MessageStrings[msgid]);
        [self handleInputEvent:msgid data:data];
    }
}


- (void)handleInputEvent:(int)msgid data:(NSData *)data
{
    if (ScrollWheelMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;

        int row = *((int*)bytes);  bytes += sizeof(int);
        int col = *((int*)bytes);  bytes += sizeof(int);
        int flags = *((int*)bytes);  bytes += sizeof(int);
        float dy = *((float*)bytes);  bytes += sizeof(float);
        float dx = *((float*)bytes);  bytes += sizeof(float);

        int button = MOUSE_5;
        if (dy < 0) button = MOUSE_5;
        else if (dy > 0) button = MOUSE_4;
        else if (dx < 0) button = MOUSE_6;
        else if (dx > 0) button = MOUSE_7;

        flags = EventModifierFlagsToVimMouseModMask(flags);

        int numLines = (dy != 0) ? (int)round(dy) : (int)round(dx);
        if (numLines < 0) numLines = -numLines;

        if (numLines != 0) {
#ifdef FEAT_GUI_SCROLL_WHEEL_FORCE
            gui.scroll_wheel_force = numLines;
#endif
            gui_send_mouse_event(button, col, row, NO, flags);
        }

#ifdef FEAT_BEVAL
        if (p_beval && balloonEval) {
            // Update the balloon eval message after a slight delay (to avoid
            // calling it too often).
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(bevalCallback:) object:nil];
            [self performSelector:@selector(bevalCallback:) withObject:nil afterDelay:MMBalloonEvalInternalDelay];
        }
#endif
    } else if (MouseDownMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;

        int row = *((int*)bytes);  bytes += sizeof(int);
        int col = *((int*)bytes);  bytes += sizeof(int);
        int button = *((int*)bytes);  bytes += sizeof(int);
        int flags = *((int*)bytes);  bytes += sizeof(int);
        int repeat = *((int*)bytes);  bytes += sizeof(int);

        button = EventButtonNumberToVimMouseButton(button);
        if (button >= 0) {
            flags = EventModifierFlagsToVimMouseModMask(flags);
            gui_send_mouse_event(button, col, row, repeat, flags);
        }
    } else if (MouseUpMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;

        int row = *((int*)bytes);  bytes += sizeof(int);
        int col = *((int*)bytes);  bytes += sizeof(int);
        int flags = *((int*)bytes);  bytes += sizeof(int);

        flags = EventModifierFlagsToVimMouseModMask(flags);

        gui_send_mouse_event(MOUSE_RELEASE, col, row, NO, flags);
    } else if (MouseDraggedMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;

        int row = *((int*)bytes);  bytes += sizeof(int);
        int col = *((int*)bytes);  bytes += sizeof(int);
        int flags = *((int*)bytes);  bytes += sizeof(int);

        flags = EventModifierFlagsToVimMouseModMask(flags);

        gui_send_mouse_event(MOUSE_DRAG, col, row, NO, flags);
    } else if (MouseMovedMsgID == msgid) {
        const void *bytes = data.bytes;
        int row = *((int*)bytes);  bytes += sizeof(int);
        int col = *((int*)bytes);  bytes += sizeof(int);

        gui_mouse_moved(col, row);

#ifdef FEAT_BEVAL
        if (p_beval && balloonEval) {
            balloonEval->x = col;
            balloonEval->y = row;

            // Update the balloon eval message after a slight delay (to avoid
            // calling it too often).
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(bevalCallback:) object:nil];
            [self performSelector:@selector(bevalCallback:) withObject:nil afterDelay:MMBalloonEvalInternalDelay];
        }
#endif
    } else if (AddInputMsgID == msgid) {
        NSString *string = [[NSString alloc] initWithData:data
                encoding:NSUTF8StringEncoding];
        if (string) {
            [self addInput:string];
        }
    } else if (SelectTabMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        int idx = *((int*)bytes) + 1;
        send_tabline_event(idx);
    } else if (CloseTabMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        int idx = *((int*)bytes) + 1;
        send_tabline_menu_event(idx, TABLINE_MENU_CLOSE);
        [self redrawScreen];
    } else if (AddNewTabMsgID == msgid) {
        send_tabline_menu_event(0, TABLINE_MENU_NEW);
        [self redrawScreen];
    } else if (DraggedTabMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        // NOTE! The destination index is 0 based, so do not add 1 to make it 1
        // based.
        int idx = *((int*)bytes);

        tabpage_move(idx);
    } else if (SetTextDimensionsMsgID == msgid || LiveResizeMsgID == msgid
            || SetTextDimensionsNoResizeWindowMsgID == msgid
            || SetTextRowsMsgID == msgid || SetTextColumnsMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        int rows = Rows;
        if (SetTextColumnsMsgID != msgid) {
            rows = *((int*)bytes);  bytes += sizeof(int);
        }
        int cols = Columns;
        if (SetTextRowsMsgID != msgid) {
            cols = *((int*)bytes);  bytes += sizeof(int);
        }

        NSData *d = data;
        if (SetTextRowsMsgID == msgid || SetTextColumnsMsgID == msgid) {
            int dim[2] = { rows, cols };
            d = [NSData dataWithBytes:dim length:2*sizeof(int)];
            msgid = SetTextDimensionsReplyMsgID;
        }

        if (SetTextDimensionsMsgID == msgid)
            msgid = SetTextDimensionsReplyMsgID;

        // NOTE! Vim doesn't call gui_mch_set_shellsize() after
        // gui_resize_shell(), so we have to manually set the rows and columns
        // here since MacVim doesn't change the rows and columns to avoid
        // inconsistent states between Vim and MacVim.  The message sent back
        // indicates that it is a reply to a message that originated in MacVim
        // since we need to be able to determine where a message originated.
        [self queueMessage:msgid data:d];

        gui_resize_shell(cols, rows);
    } else if (ResizeViewMsgID == msgid) {
        [self queueMessage:msgid data:data];
    } else if (ExecuteMenuMsgID == msgid) {
        NSDictionary *attrs = [NSDictionary dictionaryWithData:data];
        if (attrs) {
            NSArray *desc = attrs[@"descriptor"];
            vimmenu_T *menu = menu_for_descriptor(desc);
            if (menu) gui_menu_cb(menu);
        }
    } else if (ToggleToolbarMsgID == msgid) {
        [self handleToggleToolbar];
    } else if (ScrollbarEventMsgID == msgid) {
        [self handleScrollbarEvent:data];
    } else if (SetFontMsgID == msgid) {
        [self handleSetFont:data];
    } else if (VimShouldCloseMsgID == msgid) {
        gui_shell_closed();
    } else if (DropFilesMsgID == msgid) {
        [self handleDropFiles:data];
    } else if (DropStringMsgID == msgid) {
        [self handleDropString:data];
    } else if (GotFocusMsgID == msgid) {
        if (!gui.in_focus)
            [self focusChange:YES];
    } else if (LostFocusMsgID == msgid) {
        if (gui.in_focus)
            [self focusChange:NO];
    } else if (SetMouseShapeMsgID == msgid) {
        const void *bytes = data.bytes;
        int shape = *((int*)bytes);  bytes += sizeof(int);
        update_mouseshape(shape);
    } else if (XcodeModMsgID == msgid) {
        [self handleXcodeMod:data];
    } else if (OpenWithArgumentsMsgID == msgid) {
        [self handleOpenWithArguments:[NSDictionary dictionaryWithData:data]];
    } else if (FindReplaceMsgID == msgid) {
        [self handleFindReplace:[NSDictionary dictionaryWithData:data]];
    } else if (ZoomMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        int rows = *((int*)bytes);  bytes += sizeof(int);
        int cols = *((int*)bytes);  bytes += sizeof(int);
        //int zoom = *((int*)bytes);  bytes += sizeof(int);

        // NOTE: The frontend sends zoom messages here causing us to
        // immediately resize the shell and mirror the message back to the
        // frontend.  This is done to ensure that the draw commands reach the
        // frontend before the window actually changes size in order to avoid
        // flickering.  (Also see comment in SetTextDimensionsReplyMsgID
        // regarding resizing.)
        [self queueMessage:ZoomMsgID data:data];
        gui_resize_shell(cols, rows);
    } else if (SetWindowPositionMsgID == msgid) {
        if (!data) return;
        const void *bytes = data.bytes;
        _windowPosition.col = *((int *)bytes);  bytes += sizeof(int);
        _windowPosition.row = *((int *)bytes);  bytes += sizeof(int);
        ASLogDebug(@"SetWindowPositionMsgID: x=%d y=%d", _windowPosition.col, _windowPosition.row);
    } else if (GestureMsgID == msgid) {
        [self handleGesture:data];
    } else if (ActivatedImMsgID == msgid) {
        [self setImState:YES];
    } else if (DeactivatedImMsgID == msgid) {
        [self setImState:NO];
    } else if (BackingPropertiesChangedMsgID == msgid) {
        [self redrawScreen];
    } else {
        ASLogWarn(@"Unknown message received (msgid=%d)", msgid);
    }
}

- (void)doKeyDown:(NSString *)key keyCode:(unsigned)code modifiers:(int)modifiers
{
    ASLogDebug(@"key='%@' code=%#x modifiers=%#x length=%ld", key, code, modifiers, key.length);
    if (!key) return;

    char_u *str = (char_u *)key.UTF8String;
    int length = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    if ([self handleSpecialKey:key keyCode:code modifiers:modifiers]) return;

#ifdef FEAT_MBYTE
    char_u *conv_str = NULL;
    if (input_conv.vc_type != CONV_NONE) {
        conv_str = string_convert(&input_conv, str, &length);
        if (conv_str) str = conv_str;
    }
#endif

    if (modifiers & MOD_MASK_CMD) {
        // NOTE: For normal input (non-special, 'macmeta' off) the modifier
        // flags are already included in the key event.  However, the Cmd key
        // flag is special and must always be added manually.
        // The Shift flag is already included in the key when the Command
        // key is held.  The same goes for Alt, unless Ctrl is held or
        // 'macmeta' is set.  It is important that these flags are cleared
        // _after_ special keys have been handled, since they should never be
        // cleared for special keys.
        modifiers &= ~MOD_MASK_SHIFT;
        if (!(modifiers & MOD_MASK_CTRL)) {
            const BOOL mmta = curbuf ? curbuf->b_p_mmta : YES;
            if (!mmta) modifiers &= ~MOD_MASK_ALT;
        }

        ASLogDebug(@"add modifiers=%#x", modifiers);
        char_u chars[] = {CSI, KS_MODIFIER, modifiers};
        add_to_input_buf(chars, sizeof(chars));
    } else if (modifiers & MOD_MASK_ALT && 1 == length && str[0] < 0x80 && curbuf && curbuf->b_p_mmta) {
        // HACK! The 'macmeta' is set so we have to handle Alt key presses
        // separately.  Normally Alt key presses are interpreted by the
        // frontend but now we have to manually set the 8th bit and deal with
        // UTF-8 conversion.
        if ([self handleMacMetaKey:str[0] modifiers:modifiers]) return;
    }


    for (int i = 0; i < length; ++i) {
        ASLogDebug(@"add byte [%d/%d]: %#x", i, length, str[i]);
        add_to_input_buf(str + i, 1);
        if (CSI == str[i]) {
            // NOTE: If the converted string contains the byte CSI, then it
            // must be followed by the bytes KS_EXTRA, KE_CSI or things
            // won't work.
            static char_u extra[] = {KS_EXTRA, KE_CSI};
            ASLogDebug(@"add KS_EXTRA, KE_CSI");
            add_to_input_buf(extra, sizeof(extra));
        }
    }

#ifdef FEAT_MBYTE
    if (conv_str)
        vim_free(conv_str);
#endif
}

- (BOOL)handleSpecialKey:(NSString *)key keyCode:(unsigned)code modifiers:(int)modifiers
{
    SpecialKey *found = nil;
    for (size_t i = 0; specialKeys[i].keysym != 0; i++) {
        if (specialKeys[i].keysym == code) {
            ASLogDebug(@"Special key: %#x", code);
            found = &specialKeys[i];
            break;
        }
    }
    if (!found) return NO;

    int ikey = found->code1 == NUL ? found->code0 : TO_SPECIAL(found->code0, found->code1);
    ikey = simplify_key(ikey, &modifiers);
    if (ikey == CSI) ikey = K_CSI;

    char_u chars[4];
    int len = 0;

    if (IS_SPECIAL(ikey)) {
        chars[0] = CSI;
        chars[1] = K_SECOND(ikey);
        chars[2] = K_THIRD(ikey);
        len = 3;
    } else if (modifiers & MOD_MASK_ALT && found->code1 == 0
#ifdef FEAT_MBYTE
            && !enc_dbcs    // TODO: ?  (taken from gui_gtk_x11.c)
#endif
            ) {
        ASLogDebug(@"Alt special=%d", ikey);

        // NOTE: The last entries in the specialKeys struct when pressed
        // together with Alt need to be handled separately or they will not
        // work.
        // The following code was gleaned from gui_gtk_x11.c.
        modifiers &= ~MOD_MASK_ALT;
        int mkey = 0x80 | ikey;
#ifdef FEAT_MBYTE
        if (enc_utf8) {  // TODO: What about other encodings?
            // Convert to utf-8
            chars[0] = (mkey >> 6) + 0xc0;
            chars[1] = mkey & 0xbf;
            if (chars[1] == CSI) {
                // We end up here when ikey == ESC
                chars[2] = KS_EXTRA;
                chars[3] = KE_CSI;
                len = 4;
            } else {
                len = 2;
            }
        } else
#endif
        {
            chars[0] = mkey;
            len = 1;
        }
    } else {
        ASLogDebug(@"Just ikey=%d", ikey);
        chars[0] = ikey;
        len = 1;
    }

    if (len > 0) {
        if (modifiers) {
            ASLogDebug(@"Adding modifiers to special: %d", modifiers);
            char_u chars[] = {CSI, KS_MODIFIER, (char_u)modifiers};
            add_to_input_buf(chars, sizeof(chars));
        }
        ASLogDebug(@"Adding special (%d): %x,%x,%x", len, chars[0], chars[1], chars[2]);
        add_to_input_buf(chars, len);
    }

    return YES;
}

- (BOOL)handleMacMetaKey:(int)ikey modifiers:(int)modifiers
{
    ASLogDebug(@"ikey=%d modifiers=%d", ikey, modifiers);

    // This code was taken from gui_w48.c and gui_gtk_x11.c.
    char_u string[7];
    int ch = simplify_key(ikey, &modifiers);

    // Remove the SHIFT modifier for keys where it's already included,
    // e.g., '(' and '*'
    if (ch < 0x100 && !isalpha(ch) && isprint(ch)) modifiers &= ~MOD_MASK_SHIFT;

    // Interpret the ALT key as making the key META, include SHIFT, etc.
    ch = extract_modifiers(ch, &modifiers);
    if (ch == CSI) ch = K_CSI;

    int len = 0;
    if (modifiers) {
        string[len++] = CSI;
        string[len++] = KS_MODIFIER;
        string[len++] = modifiers;
    }

    string[len++] = ch;
#ifdef FEAT_MBYTE
    // TODO: What if 'enc' is not "utf-8"?
    if (enc_utf8 && (ch & 0x80)) { // convert to utf-8
        string[len++] = ch & 0xbf;
        string[len-2] = ((unsigned)ch >> 6) + 0xc0;
        if (string[len-1] == CSI) {
            string[len++] = KS_EXTRA;
            string[len++] = (int)KE_CSI;
        }
    }
#endif

    add_to_input_buf(string, len);
    return YES;
}

- (void)queueMessage:(int)msgid data:(NSData *)data
{
    [_outputQueue addObject:[NSData dataWithBytes:&msgid length:sizeof(msgid)]];
    [_outputQueue addObject:data ?: NSData.new];
}

- (void)connectionDidDie:(NSNotification *)notification
{
    // If the main connection to MacVim is lost this means that either MacVim
    // has crashed or this process did not receive its termination message
    // properly (e.g. if the TerminateNowMsgID was dropped).
    //
    // NOTE: This is not called if a Vim controller invalidates its connection.

    ASLogNotice(@"Main connection was lost before process had a chance to terminate; preserving swap files.");
    getout_preserve_modified(1);
}

- (void)blinkTimerFired:(NSTimer *)timer
{
#if 0
    NSTimeInterval interval = 0;

    _blinkTimer = nil;

    if (MMBlinkStateOn == _blinkState) {
        gui_undraw_cursor();
        _blinkState = MMBlinkStateOff;
        interval = _blinkOffInterval;
    } else if (MMBlinkStateOff == _blinkState) {
        gui_update_cursor(TRUE, FALSE);
        _blinkState = MMBlinkStateOn;
        interval = _blinkOnInterval;
    }

    if (interval > 0) {
        _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(blinkTimerFired:) userInfo:nil repeats:NO];
        [self flushQueue:YES];
    }
#endif
}

- (void)focusChange:(BOOL)on
{
    gui_focus_change(on);
}

- (void)handleToggleToolbar
{
    // If 'go' contains 'T', then remove it, else add it.

    char_u go[sizeof(GO_ALL) + 2];
    char_u *p;
    int len;

    STRCPY(go, p_go);
    p = vim_strchr(go, GO_TOOLBAR);
    len = STRLEN(go);

    if (p) {
        char_u *end = go + len;
        while (p < end) {
            p[0] = p[1];
            ++p;
        }
    } else {
        go[len] = GO_TOOLBAR;
        go[len+1] = NUL;
    }

    set_option_value((char_u *)"guioptions", 0, go, 0);
}

- (void)handleScrollbarEvent:(NSData *)data
{
    if (!data) return;

    const void *bytes = data.bytes;
    int32_t ident = *((int32_t *)bytes);  bytes += sizeof(int32_t);
    int hitPart = *((int *)bytes);  bytes += sizeof(int);
    float fval = *((float *)bytes);  bytes += sizeof(float);
    scrollbar_T *sb = gui_find_scrollbar(ident);

    if (sb) {
        scrollbar_T *sb_info = sb->wp ? &sb->wp->w_scrollbars[0] : sb;
        long value = sb_info->value;
        long size = sb_info->size;
        long max = sb_info->max;
        BOOL isStillDragging = NO;
        BOOL updateKnob = YES;

        switch (hitPart) {
        case NSScrollerDecrementPage:
            value -= (size > 2 ? size - 2 : 1);
            break;
        case NSScrollerIncrementPage:
            value += (size > 2 ? size - 2 : 1);
            break;
        case NSScrollerDecrementLine:
            --value;
            break;
        case NSScrollerIncrementLine:
            ++value;
            break;
        case NSScrollerKnob:
            isStillDragging = YES;
            // fall through ...
        case NSScrollerKnobSlot:
            value = (long)(fval * (max - size + 1));
            // fall through ...
        default:
            updateKnob = NO;
            break;
        }

        gui_drag_scrollbar(sb, value, isStillDragging);

        if (updateKnob) {
            // Dragging the knob or option+clicking automatically updates
            // the knob position (on the actual NSScroller), so we only
            // need to set the knob position in the other cases.
            if (sb->wp) {
                // Update both the left&right vertical scrollbars.
                int32_t idL = (int32_t)sb->wp->w_scrollbars[SBAR_LEFT].ident;
                int32_t idR = (int32_t)sb->wp->w_scrollbars[SBAR_RIGHT].ident;
                [self setScrollbarThumbValue:value size:size max:max identifier:idL];
                [self setScrollbarThumbValue:value size:size max:max identifier:idR];
            } else {
                // Update the horizontal scrollbar.
                [self setScrollbarThumbValue:value size:size max:max identifier:ident];
            }
        }
    }
}

- (void)handleSetFont:(NSData *)data
{
    if (!data) return;

    const void *bytes = data.bytes;
    int pointSize = (int)*((float *)bytes);  bytes += sizeof(float);

    unsigned len = *((unsigned *)bytes);  bytes += sizeof(unsigned);
    NSMutableString *name = [NSMutableString stringWithUTF8String:bytes];
    bytes += len;

    [name appendString:[NSString stringWithFormat:@":h%d", pointSize]];
    char_u *cstring = (char_u *)name.UTF8String;

    unsigned wlen = *((unsigned *)bytes);  bytes += sizeof(unsigned);
    char_u *ws = NULL;
    if (wlen > 0) {
        NSMutableString *wname = [NSMutableString stringWithUTF8String:bytes];
        bytes += wlen;

        [wname appendString:[NSString stringWithFormat:@":h%d", pointSize]];
        ws = (char_u *)wname.UTF8String;
    }

#ifdef FEAT_MBYTE
    cstring = CONVERT_FROM_UTF8(cstring);
    if (ws) ws = CONVERT_FROM_UTF8(ws);
#endif

    set_option_value((char_u *)"guifont", 0, cstring, 0);

    if (ws && gui.wide_font != NOFONT) {
        // NOTE: This message is sent on Cmd-+/Cmd-- and as such should only
        // change the wide font if 'gfw' is non-empty (the frontend always has
        // some wide font set, even if 'gfw' is empty).
        set_option_value((char_u *)"guifontwide", 0, ws, 0);
    }

#ifdef FEAT_MBYTE
    if (ws) CONVERT_FROM_UTF8_FREE(ws);
    CONVERT_FROM_UTF8_FREE(cstring);
#endif

    [self redrawScreen];
}

- (void)handleDropFiles:(NSData *)data
{
    // TODO: Get rid of this method; instead use Vim script directly.  At the
    // moment I know how to do this to open files in tabs, but I'm not sure how
    // to add the filenames to the command line when in command line mode.

    if (!data) return;

    NSMutableDictionary *args = [NSMutableDictionary dictionaryWithData:data];
    if (!args) return;

    const id obj = args[@"forceOpen"];
    const BOOL forceOpen = obj ? [obj boolValue] : YES;

    NSArray *filenames = args[@"filenames"];
    if (filenames.count == 0) return;

#ifdef FEAT_DND
    if (!forceOpen && (State & CMDLINE)) {
        // HACK!  If Vim is in command line mode then the files names
        // should be added to the command line, instead of opening the
        // files in tabs (unless forceOpen is set).  This is taken care of by
        // gui_handle_drop().
        const NSUInteger fileCount = filenames.count;
        char_u **fnames = (char_u **)alloc(fileCount * sizeof(char_u *));
        if (fnames) {
            for (NSUInteger i = 0; i < fileCount; ++i)
                fnames[i] = [filenames[i] vimStringSave];

            // NOTE!  This function will free 'fnames'.
            // HACK!  It is assumed that the 'x' and 'y' arguments are
            // unused when in command line mode.
            gui_handle_drop(0, 0, 0, fnames, fileCount);
        }
    } else
#endif // FEAT_DND
    {
        [self handleOpenWithArguments:args];
    }
}

- (void)handleDropString:(NSData *)data
{
    if (!data) return;

#ifdef FEAT_DND
    char_u dropkey[] = {CSI, KS_EXTRA, (char_u)KE_DROP};
    const void *bytes = data.bytes;
    const int ignore __attribute__((unused)) = *((int *)bytes);  bytes += sizeof(int);
    NSMutableString *string = [NSMutableString stringWithUTF8String:bytes];

    // Replace unrecognized end-of-line sequences with \x0a (line feed).
    const NSRange range = {0, string.length};
    unsigned n = [string replaceOccurrencesOfString:@"\x0d\x0a" withString:@"\x0a" options:0 range:range];
    if (0 == n) {
        n = [string replaceOccurrencesOfString:@"\x0d" withString:@"\x0a" options:0 range:range];
    }

    int len = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    char_u *cstring = (char_u *)string.UTF8String;
#ifdef FEAT_MBYTE
    if (input_conv.vc_type != CONV_NONE) cstring = string_convert(&input_conv, cstring, &len);
#endif
    dnd_yank_drag_data(cstring, len);
#ifdef FEAT_MBYTE
    if (input_conv.vc_type != CONV_NONE) vim_free(cstring);
#endif
    add_to_input_buf(dropkey, sizeof(dropkey));
#endif // FEAT_DND
}

- (void)startOdbEditWithArguments:(NSDictionary *)args
{
#ifdef FEAT_ODB_EDITOR
    id obj = [args objectForKey:@"remoteID"];
    if (!obj) return;

    OSType serverID = [obj unsignedIntValue];
    NSString *remotePath = args[@"remotePath"];

    NSAppleEventDescriptor *token = nil;
    NSData *tokenData = args[@"remoteTokenData"];
    obj = args[@"remoteTokenDescType"];
    if (tokenData && obj) {
        const DescType tokenType = [obj unsignedLongValue];
        token = [NSAppleEventDescriptor descriptorWithDescriptorType:tokenType data:tokenData];
    }

    for (NSString *filename in (NSArray *)args[@"filenames"]) {
        char_u *cstring = filename.vimStringSave;
        buf_T *buf = buflist_findname(cstring);
        vim_free(cstring);

        if (buf) {
            if (buf->b_odb_token) {
                buf->b_odb_token = NULL;
            }
            if (buf->b_odb_fname) {
                vim_free(buf->b_odb_fname);
                buf->b_odb_fname = NULL;
            }
            buf->b_odb_server_id = serverID;

            if (token) buf->b_odb_token = (__bridge_retained void *)token;
            if (remotePath) buf->b_odb_fname = remotePath.vimStringSave;
        } else {
            ASLogWarn(@"Could not find buffer '%@' for ODB editing.", filename);
        }
    }
#endif // FEAT_ODB_EDITOR
}

- (void)handleXcodeMod:(NSData *)data
{
}

- (void)handleOpenWithArguments:(NSDictionary *)args
{
    // ARGUMENT:                DESCRIPTION:
    // -------------------------------------------------------------
    // filenames                list of filenames
    // dontOpen                 don't open files specified in above argument
    // layout                   which layout to use to open files
    // selectionRange           range of characters to select
    // searchText               string to search for
    // cursorLine               line to position the cursor on
    // cursorColumn             column to position the cursor on
    //                          (only valid when "cursorLine" is set)
    // remoteID                 ODB parameter
    // remotePath               ODB parameter
    // remoteTokenDescType      ODB parameter
    // remoteTokenData          ODB parameter

    ASLogDebug(@"args=%@ (starting=%d)", args, starting);

    NSArray *filenames = args[@"filenames"];
    BOOL openFiles = ![args[@"dontOpen"] boolValue];
    int layout = [args[@"layout"] intValue];

    if (starting > 0) {
        // When Vim is starting we simply add the files to be opened to the
        // global arglist and Vim will take care of opening them for us.
        if (openFiles && filenames.count != 0) {
            for (NSString *filename in filenames) {
                char_u *p = NULL;
                if (ga_grow(&global_alist.al_ga, 1) == FAIL || !(p = filename.vimStringSave))
                    exit(2); // See comment in -[MMBackend exit]
                else
                    alist_add(&global_alist, p, 2);
            }

            // Vim will take care of arranging the files added to the arglist
            // in windows or tabs; all we must do is to specify which layout to
            // use.
            _initialWindowLayout = layout;

            // Change to directory of first file to open.
            // NOTE: This is only done when Vim is starting to avoid confusion:
            // if a window is already open the pwd is never touched.
            if (openFiles && filenames.count != 0 && !args[@"remoteID"]) {
                char_u *s = [filenames.firstObject vimStringSave];
                if (mch_isdir(s)) {
                    mch_chdir((char *)s);
                } else {
                    vim_chdirfile(s, "drop");
                }
                vim_free(s);
            }
        }
    } else {
        // When Vim is already open we resort to some trickery to open the
        // files with the specified layout.
        //
        // TODO: Figure out a better way to handle this?
        if (openFiles && filenames.count != 0) {
            BOOL oneWindowInTab = topframe ? YES : (topframe->fr_layout == FR_LEAF);
            BOOL bufChanged = NO;
            BOOL bufHasFilename = NO;
            if (curbuf) {
                bufChanged = curbufIsChanged();
                bufHasFilename = curbuf->b_ffname != NULL;
            }

            // Temporarily disable flushing since the following code may
            // potentially cause multiple redraws.
            _flushDisabled = YES;

            if (WIN_TABS == layout && first_tabpage->tp_next) {
                // By going to the last tabpage we ensure that the new tabs
                // will appear last (if this call is left out, the taborder
                // becomes messy).
                goto_tabpage(9999);
            }

            // Make sure we're in normal mode first.
            [self addInput:@"<C-\\><C-N>"];

            if (filenames.count > 1) {
                // With "split layout" we open a new tab before opening
                // multiple files if the current tab has more than one window
                // or if there is exactly one window but whose buffer has a
                // filename.  (The :drop command ensures modified buffers get
                // their own window.)
                if ((WIN_HOR == layout || WIN_VER == layout) && (!oneWindowInTab || bufHasFilename))
                    [self addInput:@":tabnew<CR>"];

                // The files are opened by constructing a ":drop ..." command
                // and executing it.
                NSMutableString *cmd = (WIN_TABS == layout ? @":tab drop" : @":drop").mutableCopy;

                for (NSString *file in filenames) {
                    [cmd appendString:@" "];
                    [cmd appendString:file.stringByEscapingSpecialFilenameCharacters];
                }

                // Temporarily clear 'suffixes' so that the files are opened in
                // the same order as they appear in the "filenames" array.
                [self addInput:@":let mvim_oldsu=&su|set su=<CR>"];

                [self addInput:cmd];

                // Split the view into multiple windows if requested.
                if (WIN_HOR == layout) [self addInput:@"|sall"];
                else if (WIN_VER == layout) [self addInput:@"|vert sall"];

                // Restore the old value of 'suffixes'.
                [self addInput:@"|let &su=mvim_oldsu|unlet mvim_oldsu<CR>"];
            } else {
                // When opening one file we try to reuse the current window,
                // but not if its buffer is modified or has a filename.
                // However, the 'arglist' layout always opens the file in the
                // current window.
                NSString *file = [filenames.lastObject stringByEscapingSpecialFilenameCharacters];
                NSString *cmd;
                if (WIN_HOR == layout) {
                    if (!(bufHasFilename || bufChanged))
                        cmd = [NSString stringWithFormat:@":e %@", file];
                    else
                        cmd = [NSString stringWithFormat:@":sp %@", file];
                } else if (WIN_VER == layout) {
                    if (!(bufHasFilename || bufChanged))
                        cmd = [NSString stringWithFormat:@":e %@", file];
                    else
                        cmd = [NSString stringWithFormat:@":vsp %@", file];
                } else if (WIN_TABS == layout) {
                    if (oneWindowInTab && !(bufHasFilename || bufChanged))
                        cmd = [NSString stringWithFormat:@":e %@", file];
                    else
                        cmd = [NSString stringWithFormat:@":tabe %@", file];
                } else {
                    // (The :drop command will split if there is a modified
                    // buffer.)
                    cmd = [NSString stringWithFormat:@":drop %@", file];
                }

                [self addInput:cmd];
                [self addInput:@"<CR>"];
            }

            // Force screen redraw (does it have to be this complicated?).
            // (This code was taken from the end of gui_handle_drop().)
            update_screen(NOT_VALID);
            setcursor();
            out_flush();
            gui_update_cursor(FALSE, FALSE);
            maketitle();

            _flushDisabled = NO;
        }
    }

    if (args[@"remoteID"]) {
        // NOTE: We have to delay processing any ODB related arguments since
        // the file(s) may not be opened until the input buffer is processed.
        [self performSelector:@selector(startOdbEditWithArguments:) withObject:args afterDelay:0];
    }

    NSString *lineString = args[@"cursorLine"];
    if (lineString && lineString.intValue > 0) {
        NSString *columnString = args[@"cursorColumn"];
        if (!(columnString && columnString.intValue > 0)) columnString = @"1";
        NSString *cmd = [NSString stringWithFormat:@"<C-\\><C-N>:cal cursor(%@,%@)|norm! zz<CR>:f<CR>", lineString, columnString];
        [self addInput:cmd];
    }

    NSString *rangeString = args[@"selectionRange"];
    if (rangeString) {
        // Build a command line string that will select the given range of
        // characters.  If range.length == 0, then position the cursor on the
        // line at start of range but do not select.
        NSRange range = NSRangeFromString(rangeString);
        NSString *cmd;
        if (range.length > 0) {
            // TODO: This only works for encodings where 1 byte == 1 character
            cmd = [NSString stringWithFormat:@"<C-\\><C-N>%ldgov%ldgo", range.location, NSMaxRange(range)-1];
        } else {
            cmd = [NSString stringWithFormat:@"<C-\\><C-N>%ldGz.0", range.location];
        }
        [self addInput:cmd];
    }

    NSString *searchText = [args objectForKey:@"searchText"];
    if (searchText) {
        // NOTE: This command may be overkill to simply search for some text,
        // but it is consistent with what is used in MMAppController.
        [self addInput:[NSString stringWithFormat:@"<C-\\><C-N>:if search('\\V\\c%@','cW')|let @/='\\V\\c%@'|set hls|endif<CR>", searchText, searchText]];
    }
}

- (int)checkForModifiedBuffers
{
    // Return 1 if current buffer is modified, -1 if other buffer is modified,
    // otherwise return 0.

    if (curbuf && bufIsChanged(curbuf)) return 1;

    for (buf_T *buf = firstbuf; buf; buf = buf->b_next) if (bufIsChanged(buf)) return -1;

    return 0;
}

- (void)addInput:(NSString *)input
{
    // NOTE: This code is essentially identical to server_to_input_buf(),
    // except the 'silent' flag is TRUE in the call to ins_typebuf() below.
    char_u *string = input.vimStringSave;
    if (!string) return;

    /* Set 'cpoptions' the way we want it.
     *    B set - backslashes are *not* treated specially
     *    k set - keycodes are *not* reverse-engineered
     *    < unset - <Key> sequences *are* interpreted
     *  The last but one parameter of replace_termcodes() is TRUE so that the
     *  <lt> sequence is recognised - needed for a real backslash.
     */
    char_u *ptr = NULL;
    char_u *cpo_save = p_cpo;
    p_cpo = (char_u *)"Bk";
    char_u *str = replace_termcodes((char_u *)string, &ptr, FALSE, TRUE, FALSE);
    p_cpo = cpo_save;

    if (*ptr) { /* trailing CTRL-V results in nothing */
        /*
         * Add the string to the input stream.
         * Can't use add_to_input_buf() here, we now have K_SPECIAL bytes.
         *
         * First clear typed characters from the typeahead buffer, there could
         * be half a mapping there.  Then append to the existing string, so
         * that multiple commands from a client are concatenated.
         */
        if (typebuf.tb_maplen < typebuf.tb_len)
            del_typebuf(typebuf.tb_len - typebuf.tb_maplen, typebuf.tb_maplen);
        (void)ins_typebuf(str, REMAP_NONE, typebuf.tb_len, TRUE, TRUE);

        /* Let input_available() know we inserted text in the typeahead
         * buffer. */
        typebuf_was_filled = TRUE;
    }
    vim_free(ptr);
    vim_free(string);
}

- (BOOL)unusedEditor
{
    const BOOL oneWindowInTab = topframe ? YES : (topframe->fr_layout == FR_LEAF);
    BOOL bufChanged = NO;
    BOOL bufHasFilename = NO;
    if (curbuf) {
        bufChanged = curbufIsChanged();
        bufHasFilename = curbuf->b_ffname != NULL;
    }

    const BOOL onlyOneTab = first_tabpage->tp_next == NULL;

    return onlyOneTab && oneWindowInTab && !bufChanged && !bufHasFilename;
}

- (void)redrawScreen
{
    // Force screen redraw (does it have to be this complicated?).
    redraw_all_later(CLEAR);
    update_screen(NOT_VALID);
    setcursor();
    out_flush();
    gui_update_cursor(FALSE, FALSE);

    // HACK! The cursor is not put back at the command line by the above
    // "redraw commands".  The following test seems to do the trick though.
    if (State & CMDLINE) redrawcmdline();
}

- (void)handleFindReplace:(NSDictionary *)args
{
    if (!args) return;

    NSString *findString = args[@"find"];
    if (!findString) return;

    char_u *find = findString.vimStringSave;
    char_u *replace = [args[@"replace"] vimStringSave];
    const int flags = [args[@"flags"] intValue];

    // NOTE: The flag 0x100 is used to indicate a backward search.
    gui_do_findrepl(flags, find, replace, (flags & 0x100) == 0);

    vim_free(find);
    vim_free(replace);
}


- (void)handleMarkedText:(NSData *)data
{
    const void *bytes = data.bytes;
    const int32_t pos = *((int32_t *)bytes);  bytes += sizeof(int32_t);
    const unsigned length = *((unsigned *)bytes);  bytes += sizeof(unsigned);
    const char *chars = (char *)bytes;

    ASLogDebug(@"pos=%d length=%d chars=%s", pos, length, chars);

    if (pos < 0) {
        im_preedit_abandon_macvim();
    } else if (length == 0) {
        im_preedit_end_macvim();
    } else {
        if (!preedit_get_status()) im_preedit_start_macvim();
        im_preedit_changed_macvim(chars, pos);
    }
}

- (void)handleGesture:(NSData *)data
{
    const void *bytes = data.bytes;
    const int flags = *((int *)bytes);  bytes += sizeof(int);
    const int gesture = *((int *)bytes);  bytes += sizeof(int);
    const int modifiers = EventModifierFlagsToVimModMask(flags);

    char_u string[6] = {CSI, KS_MODIFIER, modifiers, CSI, KS_EXTRA, 0};
    switch (gesture) {
        case MMGestureSwipeLeft:    string[5] = KE_SWIPELEFT;	break;
        case MMGestureSwipeRight:   string[5] = KE_SWIPERIGHT;	break;
        case MMGestureSwipeUp:	    string[5] = KE_SWIPEUP;	    break;
        case MMGestureSwipeDown:    string[5] = KE_SWIPEDOWN;	break;
        case MMGestureForceClick:   string[5] = KE_FORCECLICK;	break;
        default: return;
    }

    if (modifiers == 0) {
        add_to_input_buf(string + 3, 3);
    } else {
        add_to_input_buf(string, 6);
    }
}

#ifdef FEAT_BEVAL
- (void)bevalCallback:(id)sender
{
    if (!(p_beval && balloonEval)) return;

    if (balloonEval->msgCB) {
        // HACK! We have no way of knowing whether the balloon evaluation
        // worked or not, so we keep track of it using a local tool tip
        // variable.  (The reason we need to know is due to how the Cocoa tool
        // tips work: if there is no tool tip we must set it to nil explicitly
        // or it might never go away.)
        self.lastToolTip = nil;

        (*balloonEval->msgCB)(balloonEval, 0);

        [self queueMessage:SetTooltipMsgID properties:@{@"toolTip": (_lastToolTip ?: @"")}];
        [self flushQueue:YES];
    }
}
#endif

#ifdef MESSAGE_QUEUE
- (void)checkForProcessEvents:(NSTimer *)timer
{
# ifdef FEAT_TIMERS
    did_add_timer = FALSE;
# endif

    parse_queued_messages();

    if (input_available()
# ifdef FEAT_TIMERS
            || did_add_timer
# endif
            )
        CFRunLoopStop(CFRunLoopGetCurrent());
}
#endif // MESSAGE_QUEUE

@end // MMBackend (Private)

/**
 */
@implementation MMBackend (ClientServer)

- (NSString *)connectionNameFromServerName:(NSString *)name
{
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    return [NSString stringWithFormat:@"%@.%@", bundlePath, name].lowercaseString;
}

- (NSConnection *)connectionForServerName:(NSString *)name
{
    // TODO: Try 'name%d' if 'name' fails.
    NSString *connName = [self connectionNameFromServerName:name];
    NSConnection *connection = _connections[connName];
    if (connection) {
        return connection;
    }

    connection = [NSConnection connectionWithRegisteredName:connName host:nil];
    // Try alternate server...
    if (!connection && _alternateServerName) {
        ASLogInfo(@"  trying to connect to alternate server: %@", _alternateServerName);
        connName = [self connectionNameFromServerName:_alternateServerName];
        connection = [NSConnection connectionWithRegisteredName:connName host:nil];
    }

    // Try looking for alternate servers...
    if (!connection) {
        ASLogInfo(@"  looking for alternate servers...");
        NSString *alt = [self alternateServerNameForName:name];
        if (alt != _alternateServerName) {
            ASLogInfo(@"  found alternate server: %@", alt);
            _alternateServerName = alt.copy;
        }
    }

    // Try alternate server again...
    if (!connection && _alternateServerName) {
        ASLogInfo(@"  trying to connect to alternate server: %@", _alternateServerName);
        connName = [self connectionNameFromServerName:_alternateServerName];
        connection = [NSConnection connectionWithRegisteredName:connName host:nil];
    }

    if (connection) {
        _connections[connName] = connection;

        ASLogDebug(@"Adding %@ as connection observer for %@", self, connection);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(serverConnectionDidDie:) name:NSConnectionDidDieNotification object:connection];
    }

    return connection;
}

- (NSConnection *)connectionForServerPort:(int)port
{
    for (NSConnection *connection in _connections.allValues) {
        // HACK! Assume connection uses mach ports.
        if (port == [(NSMachPort *)connection.sendPort machPort])
            return connection;
    }

    return nil;
}

- (void)serverConnectionDidDie:(NSNotification *)notification
{
    ASLogDebug(@"notification=%@", notification);

    NSConnection *serverConnection = notification.object;

    ASLogDebug(@"Removing %@ as connection observer from %@", self, serverConnection);
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSConnectionDidDieNotification object:serverConnection];

    [_connections removeObjectsForKeys:[_connections allKeysForObject:serverConnection]];

    // HACK! Assume connection uses mach ports.
    int port = [(NSMachPort*)serverConnection.sendPort machPort];
    NSNumber *key = @(port);

    [_clients removeObjectForKey:key];
    [_serverReplyDict removeObjectForKey:key];
}

- (void)addClient:(NSDistantObject *)client
{
    NSConnection *conn = [client connectionForProxy];
    // HACK! Assume connection uses mach ports.
    const int port = [(NSMachPort *)conn.sendPort machPort];
    NSNumber *key = @(port);

    if (!_clients[key]) {
        [client setProtocolForProxy:@protocol(MMVimClientProtocol)];
        _clients[key] = client;
    }

    // NOTE: 'clientWindow' is a global variable which is used by <client>
    clientWindow = port;
}

- (NSString *)alternateServerNameForName:(NSString *)name
{
    if (!(name && name.length > 0))
        return nil;

    // Only look for alternates if 'name' doesn't end in a digit.
    const unichar lastChar = [name characterAtIndex:name.length - 1];
    if (lastChar >= '0' && lastChar <= '9') return nil;

    // Look for alternates among all current servers.
    NSArray *list = self.serverList;
    if (list.count == 0) return nil;

    // Filter out servers starting with 'name' and ending with a number. The
    // (?i) pattern ensures that the match is case insensitive.
    NSString *pat = [NSString stringWithFormat:@"(?i)%@[0-9]+\\z", name];
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", pat];
    list = [list filteredArrayUsingPredicate:pred];
    if (list.count != 0) {
        list = [list sortedArrayUsingSelector:@selector(serverNameCompare:)];
        return list.firstObject;
    }

    return nil;
}

@end // MMBackend (ClientServer)

/**
 */
@implementation NSString (MMServerNameCompare)
- (NSComparisonResult)serverNameCompare:(NSString *)string
{
    return [self compare:string options:NSCaseInsensitiveSearch | NSNumericSearch];
}
@end


// This function is modeled after the VimToPython function found in if_python.c
// NB This does a deep copy by value, it does not lookup references like the
// VimToPython function does.  This is because I didn't want to deal with the
// retain cycles that this would create, and we can cover 99% of the use cases
// by ignoring it.  If we ever switch to using GC in MacVim then this
// functionality can be implemented easily.
static id vimToCocoa(typval_T * tv, int depth)
{
    id result = nil;
    id newObj = nil;


    // Avoid infinite recursion
    if (depth > 100) {
        return nil;
    }

    if (tv->v_type == VAR_STRING) {
        char_u * val = tv->vval.v_string;
        // val can be NULL if the string is empty
        if (!val) {
            result = [NSString string];
        } else {
#ifdef FEAT_MBYTE
            val = CONVERT_TO_UTF8(val);
#endif
            result = [NSString stringWithUTF8String:(char*)val];
#ifdef FEAT_MBYTE
            CONVERT_TO_UTF8_FREE(val);
#endif
        }
    } else if (tv->v_type == VAR_NUMBER) {
        // looks like sizeof(varnumber_T) is always <= sizeof(long)
        result = [NSNumber numberWithLong:(long)tv->vval.v_number];
    } else if (tv->v_type == VAR_LIST) {
        list_T * list = tv->vval.v_list;
        listitem_T * curr;

        NSMutableArray * arr = result = [NSMutableArray array];

        if (list != NULL) {
            for (curr = list->lv_first; curr != NULL; curr = curr->li_next) {
                newObj = vimToCocoa(&curr->li_tv, depth + 1);
                [arr addObject:newObj];
            }
        }
    } else if (tv->v_type == VAR_DICT) {
        NSMutableDictionary * dict = result = [NSMutableDictionary dictionary];

        if (tv->vval.v_dict != NULL) {
            hashtab_T * ht = &tv->vval.v_dict->dv_hashtab;
            int todo = ht->ht_used;
            hashitem_T * hi;
            dictitem_T * di;

            for (hi = ht->ht_array; todo > 0; ++hi) {
                if (!HASHITEM_EMPTY(hi)) {
                    --todo;

                    di = dict_lookup(hi);
                    newObj = vimToCocoa(&di->di_tv, depth + 1);

                    char_u * keyval = hi->hi_key;
#ifdef FEAT_MBYTE
                    keyval = CONVERT_TO_UTF8(keyval);
#endif
                    NSString * key = [NSString stringWithUTF8String:(char*)keyval];
#ifdef FEAT_MBYTE
                    CONVERT_TO_UTF8_FREE(keyval);
#endif
                    [dict setObject:newObj forKey:key];
                }
            }
        }
    } else { // only func refs should fall into this category?
        result = nil;
    }

    return result;
}


// This function is modeled after eval_client_expr_to_string found in main.c
// Returns nil if there was an error evaluating the expression, and writes a
// message to errorStr.
// TODO Get the error that occurred while evaluating the expression in vim
// somehow.
static id evalExprCocoa(NSString * expr, NSString ** errstr)
{

    char_u *cstring = (char_u*)[expr UTF8String];

#ifdef FEAT_MBYTE
    cstring = CONVERT_FROM_UTF8(cstring);
#endif

    int save_dbl = debug_break_level;
    int save_ro = redir_off;

    debug_break_level = -1;
    redir_off = 0;
    ++emsg_skip;

    typval_T * tvres = eval_expr(cstring, NULL);

    debug_break_level = save_dbl;
    redir_off = save_ro;
    --emsg_skip;

    setcursor();
    out_flush();

#ifdef FEAT_MBYTE
    CONVERT_FROM_UTF8_FREE(cstring);
#endif

#ifdef FEAT_GUI
    if (gui.in_use)
        gui_update_cursor(FALSE, FALSE);
#endif

    if (tvres == NULL) {
        free_tv(tvres);
        *errstr = @"Expression evaluation failed.";
    }

    id res = vimToCocoa(tvres, 1);

    free_tv(tvres);

    if (res == nil) {
        *errstr = @"Conversion to cocoa values failed.";
    }

    return res;
}

#ifdef FEAT_BEVAL
// Seconds to delay balloon evaluation after mouse event (subtracted from
// p_bdlay so that this effectively becomes the smallest possible delay).
NSTimeInterval MMBalloonEvalInternalDelay = 0.1;
#endif

