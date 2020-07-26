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
 * MMTextViewHelper
 *
 * Contains code shared between the different text renderers.  Unfortunately it
 * is not possible to let the text renderers inherit from this class since
 * MMTextView needs to inherit from NSTextView whereas MMCoreTextView needs to
 * inherit from NSView.
 */

#import "MMTextViewHelper.h"
#import "MMVimController.h"
#import "MMWindowController.h"
#import "Miscellaneous.h"
#import "MMTextView+Protocol.h"

// The max/min drag timer interval in seconds
static const NSTimeInterval MMDragTimerMaxInterval = 0.3;
static const NSTimeInterval MMDragTimerMinInterval = 0.01;

// The number of pixels in which the drag timer interval changes
static const float MMDragAreaSize = 73.0f;

@interface MMTextViewHelper ()
@property (nonatomic, readonly) MMWindowController *windowController;
@property (nonatomic, readonly) MMVimController *vimController;

- (void)doKeyDown:(NSString *)key;
- (void)doInsertText:(NSString *)text;
- (void)startDragTimerWithInterval:(NSTimeInterval)t;
- (void)dragTimerFired:(NSTimer *)timer;
- (void)setCursor;
- (NSRect)trackingRect;
- (BOOL)inputManagerHandleMouseEvent:(NSEvent *)event;
- (void)sendMarkedText:(NSString *)text position:(int32_t)pos;
- (void)abandonMarkedText;
- (void)sendGestureEvent:(int)gesture flags:(int)flags;
@end

static BOOL
KeyboardInputSourcesEqual(TISInputSourceRef a, TISInputSourceRef b)
{
    // Define two sources to be equal iff both are non-NULL and they have
    // identical source ID strings.

    if (!(a && b)) return NO;

    NSString *as = (__bridge NSString *)(TISGetInputSourceProperty(a, kTISPropertyInputSourceID));
    NSString *bs = (__bridge NSString *)(TISGetInputSourceProperty(b, kTISPropertyInputSourceID));

    return [as isEqualToString:bs];
}

@implementation MMTextViewHelper {
    NSMutableDictionary *_signImages;
    BOOL                _useMouseTime;
    NSDate              *_mouseDownTime;
    BOOL                _isDragging;
    int                 _dragRow;
    int                 _dragColumn;
    int                 _dragFlags;
    NSPoint             _dragPoint;
    BOOL                _isAutoscrolling;
    BOOL                _interpretKeyEventsSwallowedKey;
    NSEvent             *_currentEvent;
    CGPoint             _scrollingDelta;
    TISInputSourceRef   _lastInputSource;
    TISInputSourceRef   _inputSourceASCII;
}
@synthesize textView = _textView, mouseShape = _mouseShape, markedTextAttributes = _markedTextAttributes,
    insertionPointColor = _insertionPointColor,
    inputMethodRange = _inputMethodRange, markedRange = _markedRange, markedText = _markedText,
    preeditPoint = _preeditPoint, inputMethodEnabled = _inputMethodEnabled, inputSourceActivated = _inputSourceActivated;
@dynamic inlineInputMethodUsed, hasMarkedText;

- (instancetype)init
{
    if ((self = [super init]) != nil) {
        _signImages = NSMutableDictionary.new;
        _useMouseTime = [NSUserDefaults.standardUserDefaults boolForKey:MMUseMouseTimeKey];
        if (_useMouseTime) _mouseDownTime = NSDate.new;
    }
    return self;
}

- (void)dealloc
{
    if (_inputSourceASCII) {
        CFRelease(_inputSourceASCII);
        _inputSourceASCII = NULL;
    }
    if (_lastInputSource) {
        CFRelease(_lastInputSource);
        _lastInputSource = NULL;
    }
}

- (void)keyDown:(NSEvent *)event
{
    ASLogDebug(@"%@", event);

    // NOTE: Keyboard handling is complicated by the fact that we must call
    // interpretKeyEvents: otherwise key equivalents set up by input methods do
    // not work (e.g. Ctrl-Shift-; would not work under Kotoeri).

    // NOTE: insertText: and doCommandBySelector: may need to extract data from
    // the key down event so keep a local reference to the event.  This is
    // released and set to nil at the end of this method.  Don't make any early
    // returns from this method without releasing and resetting this reference!
    _currentEvent = event;

    if (self.hasMarkedText) {
        // HACK! Need to redisplay manually otherwise the marked text may not
        // be correctly displayed (e.g. it is still visible after pressing Esc
        // even though the text has been unmarked).
        _textView.needsDisplay = YES;
    }

    NSDictionary *states = self.vimController.vimState;
    const BOOL mouseHidden = [states[@"p_mh"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSCursor.hiddenUntilMouseMoves = mouseHidden;
    });

    const unsigned flags = event.modifierFlags;
    const BOOL mmta = [states[@"p_mmta"] boolValue];
    NSString *string = event.characters;
    NSString *unmod  = event.charactersIgnoringModifiers;
    const BOOL modCommand = (flags & NSEventModifierFlagCommand) ? YES : NO;
    const BOOL modControl = (flags & NSEventModifierFlagControl) ? YES : NO;
    const BOOL modOption = (flags & NSEventModifierFlagOption) ? YES : NO;
    const BOOL modShift = (flags & NSEventModifierFlagShift) ? YES : NO;


    // Alt key presses should not be interpreted if the 'macmeta' option is
    // set.  We still have to call interpretKeyEvents: for keys
    // like Enter, Esc, etc. to work as usual so only skip interpretation for
    // ASCII chars in the range after space (0x20) and before backspace (0x7f).
    // Note that this implies that 'mmta' (if enabled) breaks input methods
    // when the Alt key is held.
    if (modOption && mmta && unmod.length == 1 && [unmod characterAtIndex:0] > 0x20) {
        ASLogDebug(@"MACMETA key, don't interpret it");
        string = unmod;
    } else if (_inputSourceActivated && (modControl && !modCommand && !modOption)
            && unmod.length == 1
            && ([unmod characterAtIndex:0] == '6' ||
                [unmod characterAtIndex:0] == '^')) {
        // HACK!  interpretKeyEvents: does not call doCommandBySelector:
        // with Ctrl-6 or Ctrl-^ when IM is active.
        [self doKeyDown:@"\x1e"];
        string = nil;
#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_10)
    } else if ((flags & NSEventModifierFlagShift) && [string isEqualToString:@" "]) {
        // HACK! for Yosemite - Fix for Shift+Space inputing
        // do nothing
#endif
    } else {
        // When using JapaneseIM with "Windows-like shortcuts" turned on,
        // interpretKeyEvents: does not call doCommandBySelector: with Ctrl-O
        // and Ctrl-U (why?), so we cannot handle them at all.
        // As a workaround, we do not call interpretKeyEvents: when no marked
        // text and with only control-modifier.
        if (self.hasMarkedText || (!modControl || modCommand || modOption)) {
            // HACK!  interpretKeyEvents: may call insertText: or
            // doCommandBySelector:, or it may swallow the key (most likely the
            // current input method used it).  In the first two cases we have to
            // manually set the below flag to NO if the key wasn't handled.
            _interpretKeyEventsSwallowedKey = YES;
            [_textView interpretKeyEvents:@[event]];
            if (_interpretKeyEventsSwallowedKey)
                string = nil;
        }
        if (string && modCommand) {
            // HACK! When Command is held we have to more or less guess whether
            // we should use characters or charactersIgnoringModifiers.  The
            // following heuristic seems to work but it may have to change.
            // Note that the Shift and Alt flags may also need to be cleared
            // (see doKeyDown:keyCode:modifiers: in MMBackend).
            if ((modShift && !modOption) || modControl) {
                string = unmod;
            }
        }
    }

    if (string) [self doKeyDown:string];

    _currentEvent = nil;
}

- (void)insertText:(id)text
{
    if (self.hasMarkedText) {
        [self sendMarkedText:nil position:0];

        // NOTE: If this call is left out then the marked text isn't properly
        // erased when Return is used to accept the text.
        // The input manager only ever sets new marked text, it never actually
        // calls to have it unmarked.  It seems that whenever insertText: is
        // called the input manager expects the marked text to be unmarked
        // automatically, hence the explicit unmarkText: call here.
        [self unmarkText];
    }

    if ([text isKindOfClass:NSAttributedString.class]) text = [text string];

    [self doInsertText:text];
}

- (void)doCommandBySelector:(SEL)sel
{
    ASLogDebug(@"%@", NSStringFromSelector(sel));

    // Translate Ctrl-2 -> Ctrl-@ (see also Resources/KeyBinding.plist)
    if (@selector(keyCtrlAt:) == sel)
        [self doKeyDown:@"\x00"];
    // Translate Ctrl-6 -> Ctrl-^ (see also Resources/KeyBinding.plist)
    else if (@selector(keyCtrlHat:) == sel)
        [self doKeyDown:@"\x1e"];
    //
    // Check for selectors from AppKit.framework/StandardKeyBinding.dict and
    // send the corresponding key directly on to the backend.  The reason for
    // not just letting all of these fall through is that -[NSEvent characters]
    // sometimes includes marked text as well as the actual key, but the marked
    // text is also passed to insertText:.  For example, pressing Ctrl-i Return
    // on a US keyboard would call insertText:@"^" but the key event for the
    // Return press will contain "^\x0d" -- if we fell through the result would
    // be that "^^\x0d" got sent to the backend (i.e. one extra "^" would
    // appear).
    // For this reason we also have to make sure that there are key bindings to
    // all combinations of modifier with certain keys (these are set up in
    // KeyBinding.plist in the Resources folder).
    else if (@selector(insertTab:) == sel || @selector(selectNextKeyView:) == sel || @selector(insertTabIgnoringFieldEditor:) == sel)
        [self doKeyDown:@"\x09"];
    else if (@selector(insertNewline:) == sel || @selector(insertLineBreak:) == sel || @selector(insertNewlineIgnoringFieldEditor:) == sel)
        [self doKeyDown:@"\x0d"];
    else if (@selector(cancelOperation:) == sel || @selector(complete:) == sel)
        [self doKeyDown:@"\x1b"];
    else if (@selector(insertBackTab:) == sel || @selector(selectPreviousKeyView:) == sel)
        [self doKeyDown:@"\x19"];
    else if (@selector(deleteBackward:) == sel || @selector(deleteWordBackward:) == sel || @selector(deleteBackwardByDecomposingPreviousCharacter:) == sel ||
             @selector(deleteToBeginningOfLine:) == sel)
        [self doKeyDown:@"\x08"];
    else if (@selector(keySpace:) == sel)
        [self doKeyDown:@" "];
    else if (@selector(cancel:) == sel)
        kill(self.vimController.pid, SIGINT);
    else
        _interpretKeyEventsSwallowedKey = NO;
}

- (void)scrollWheel:(NSEvent *)event
{
    float dx = 0;
    float dy = 0;

#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
    if (event.hasPreciseScrollingDeltas) {
        const CGPoint threshold = (CGPoint){_textView.cellSize.width, _textView.cellSize.height};
        _scrollingDelta.x += event.scrollingDeltaX;
        if (fabs(_scrollingDelta.x) > threshold.x) {
            dx = roundf(_scrollingDelta.x / threshold.x);
            _scrollingDelta.x -= threshold.x * dx;
        }
        _scrollingDelta.y += event.scrollingDeltaY;
        if (fabs(_scrollingDelta.y) > threshold.y) {
            dy = roundf(_scrollingDelta.y / threshold.y);
            _scrollingDelta.y -= threshold.y * dy;
        }
    } else {
        _scrollingDelta = CGPointZero;
        dx = event.scrollingDeltaX;
        dy = event.scrollingDeltaY;
    }
#else
    dx = event.deltaX;
    dy = event.deltaY;
#endif

    if (dx == 0 && dy == 0) return;

    if (self.hasMarkedText) {
        // We must clear the marked text since the cursor may move if the
        // marked text moves outside the view as a result of scrolling.
        [self sendMarkedText:nil position:0];
        [self unmarkText];
        [NSTextInputContext.currentInputContext discardMarkedText];
    }

    int row, col;
    NSPoint pt = [_textView convertPoint:event.locationInWindow fromView:nil];
    if ([_textView convertPoint:pt toRow:&row column:&col]) {
        int flags = event.modifierFlags;
        NSMutableData *data = NSMutableData.new;
        [data appendBytes:&row length:sizeof(row)];
        [data appendBytes:&col length:sizeof(col)];
        [data appendBytes:&flags length:sizeof(flags)];
        [data appendBytes:&dy length:sizeof(dy)];
        [data appendBytes:&dx length:sizeof(dx)];

        [self.vimController sendMessage:ScrollWheelMsgID data:data];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    return;

    if ([self inputManagerHandleMouseEvent:event])
        return;

    int row, col;
    NSPoint pt = [_textView convertPoint:event.locationInWindow fromView:nil];
    if (![_textView convertPoint:pt toRow:&row column:&col])
        return;

    int button = event.buttonNumber;
    int flags = event.modifierFlags;
    int repeat = 0;

    if (_useMouseTime) {
        // Use Vim mouseTime option to handle multiple mouse down events
        NSDate *now = NSDate.new;
        const id mouset = self.vimController.vimState[@"p_mouset"];
        NSTimeInterval interval = [now timeIntervalSinceDate:_mouseDownTime] * 1000.0;
        if (interval < (NSTimeInterval)[mouset longValue]) repeat = 1;
        _mouseDownTime = now;
    } else {
        repeat = event.clickCount > 1;
    }

    NSMutableData *data = NSMutableData.new;

    // If desired, intepret Ctrl-Click as a right mouse click.
    BOOL translateCtrlClick = [NSUserDefaults.standardUserDefaults boolForKey:MMTranslateCtrlClickKey];
    flags = flags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (translateCtrlClick && button == 0 && (flags == NSEventModifierFlagControl || flags == (NSEventModifierFlagControl|NSEventModifierFlagCapsLock))) {
        button = 1;
        flags &= ~NSEventModifierFlagControl;
    }

    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];
    [data appendBytes:&button length:sizeof(int)];
    [data appendBytes:&flags length:sizeof(int)];
    [data appendBytes:&repeat length:sizeof(int)];

    [self.vimController sendMessage:MouseDownMsgID data:data];
}

- (void)mouseUp:(NSEvent *)event
{
    return;

    if ([self inputManagerHandleMouseEvent:event])
        return;

    int row, col;
    NSPoint pt = [_textView convertPoint:[event locationInWindow] fromView:nil];
    if (![_textView convertPoint:pt toRow:&row column:&col])
        return;

    int flags = event.modifierFlags;
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];
    [data appendBytes:&flags length:sizeof(int)];
    [self.vimController sendMessage:MouseUpMsgID data:data];

    _isDragging = NO;
}

- (void)mouseDragged:(NSEvent *)event
{
    return;

    if ([self inputManagerHandleMouseEvent:event])
        return;

    int flags = event.modifierFlags;
    int row, col;
    NSPoint pt = [_textView convertPoint:[event locationInWindow] fromView:nil];
    if (![_textView convertPoint:pt toRow:&row column:&col])
        return;

    // Autoscrolling is done in dragTimerFired:
    if (!_isAutoscrolling) {
        NSMutableData *data = NSMutableData.new;
        [data appendBytes:&row length:sizeof(int)];
        [data appendBytes:&col length:sizeof(int)];
        [data appendBytes:&flags length:sizeof(int)];
        [self.vimController sendMessage:MouseDraggedMsgID data:data];
    }

    _dragPoint = pt;
    _dragRow = row;
    _dragColumn = col;
    _dragFlags = flags;

    if (!_isDragging) {
        [self startDragTimerWithInterval:.5];
        _isDragging = YES;
    }
}

- (void)mouseMoved:(NSEvent *)event
{
    return;

    if ([self inputManagerHandleMouseEvent:event])
        return;

    // HACK! NSTextView has a nasty habit of resetting the cursor to the
    // default I-beam cursor at random moments.  The only reliable way we know
    // of to work around this is to set the cursor each time the mouse moves.
    [self setCursor];

    NSPoint pt = [_textView convertPoint:event.locationInWindow fromView:nil];
    int row, col;
    if (![_textView convertPoint:pt toRow:&row column:&col])
        return;

    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];
    [self.vimController sendMessage:MouseMovedMsgID data:data];
}

- (void)swipeWithEvent:(NSEvent *)event
{
    CGFloat dx = event.deltaX;
    CGFloat dy = event.deltaY;
    int type;
    if (dx > 0)	     type = MMGestureSwipeLeft;
    else if (dx < 0) type = MMGestureSwipeRight;
    else if (dy > 0) type = MMGestureSwipeUp;
    else if (dy < 0) type = MMGestureSwipeDown;
    else return;

    [self sendGestureEvent:type flags:event.modifierFlags];
}

- (void)pressureChangeWithEvent:(NSEvent *)event
{
    static BOOL inForceClick = NO;
    if (event.stage >= 2) {
        if (!inForceClick) {
            inForceClick = YES;
            [self sendGestureEvent:MMGestureForceClick flags:event.modifierFlags];
        }
    } else {
        inForceClick = NO;
    }
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    return NO;

    NSPasteboard *pboard = sender.draggingPasteboard;

    if ([pboard.types containsObject:NSStringPboardType]) {
        NSString *string = [pboard stringForType:NSStringPboardType];
        [self.vimController dropString:string];
        return YES;
    } else if ([pboard.types containsObject:NSFilenamesPboardType]) {
        NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
        [self.vimController dropFiles:files forceOpen:NO];
        return YES;
    }

    return NO;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    return NSDragOperationNone;

    NSDragOperation sourceDragMask = sender.draggingSourceOperationMask;
    NSPasteboard *pboard = sender.draggingPasteboard;

    if ([pboard.types containsObject:NSFilenamesPboardType] && (sourceDragMask & NSDragOperationCopy))
        return NSDragOperationCopy;
    if ([pboard.types containsObject:NSStringPboardType] && (sourceDragMask & NSDragOperationCopy))
        return NSDragOperationCopy;

    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return NSDragOperationNone;

    NSDragOperation sourceDragMask = sender.draggingSourceOperationMask;
    NSPasteboard *pboard = sender.draggingPasteboard;

    if ([pboard.types containsObject:NSFilenamesPboardType] && (sourceDragMask & NSDragOperationCopy))
        return NSDragOperationCopy;
    if ([pboard.types containsObject:NSStringPboardType] && (sourceDragMask & NSDragOperationCopy))
        return NSDragOperationCopy;

    return NSDragOperationNone;
}

- (void)setMouseShape:(int)shape
{
    _mouseShape = shape;
    [self setCursor];
}

- (void)changeFont:(id)sender
{
    NSFont *newFont = [sender convertFont:_textView.font];
    if (newFont) {
        NSFont *newFontWide = [sender convertFont:_textView.fontWide];

        NSString *name = newFont.displayName;
        NSString *wideName = newFontWide.displayName;
        unsigned len = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (len != 0) {
            unsigned wideLen = [wideName lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

            NSMutableData *data = NSMutableData.new;

            const float pointSize = newFont.pointSize;
            [data appendBytes:&pointSize length:sizeof(pointSize)];

            ++len;  // include NUL byte
            [data appendBytes:&len length:sizeof(len)];
            [data appendBytes:name.UTF8String length:len];

            if (wideLen != 0) {
                ++wideLen;  // include NUL byte
                [data appendBytes:&wideLen length:sizeof(wideLen)];
                [data appendBytes:wideName.UTF8String length:wideLen];
            } else {
                [data appendBytes:&wideLen length:sizeof(wideLen)];
            }

            [self.vimController sendMessage:SetFontMsgID data:data];
        }
    }
}

- (NSImage *)signImageForName:(NSString *)name
{
    NSImage *image = _signImages[name];
    if (!image) {
        image = [[NSImage alloc] initWithContentsOfFile:name];
        _signImages[name] = image;
    }
    return image;
}

- (void)deleteImage:(NSString *)name
{
    [_signImages removeObjectForKey:name];
}

- (BOOL)hasMarkedText
{
    return _markedRange.length != 0;
}

- (NSRange)markedRange
{
    if (self.hasMarkedText) return _markedRange;
    return NSMakeRange(NSNotFound, 0);
}

- (void)setMarkedText:(id)text selectedRange:(NSRange)range
{
    ASLogDebug(@"text='%@' range=%@", text, NSStringFromRange(range));
    [self unmarkText];

    if (self.inlineInputMethodUsed) {
        if ([text isKindOfClass:NSAttributedString.class]) text = [text string];
        if ([text length] != 0) {
            _markedRange = NSMakeRange(0, [text length]);
            _inputMethodRange = range;
        }
        [self sendMarkedText:text position:range.location];
        return;
    }
#ifdef INCLUDE_OLD_IM_CODE
    if ([text length] == 0) return;

    // HACK! Determine if the marked text is wide or normal width.  This seems
    // to always use 'wide' when there are both wide and normal width
    // characters.
    NSString *string = text;
    NSFont *font = _textView.font;
    if ([text isKindOfClass:NSAttributedString.class]) {
        font = _textView.fontWide;
        string = [text string];
    }

    // TODO: Use special colors for marked text.
    [self setMarkedTextAttributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: _textView.defaultForegroundColor,
        NSBackgroundColorAttributeName: _textView.defaultBackgroundColor,
    }];

    _markedText = [[NSMutableAttributedString alloc] initWithString:string attributes:_markedTextAttributes];

    _markedRange = NSMakeRange(0, _markedText.length);
    if (_markedRange.length) [_markedText addAttribute:NSUnderlineStyleAttributeName value:@(1) range:_markedRange];
    _inputMethodRange = range;
    if (range.length) [_markedText addAttribute:NSUnderlineStyleAttributeName value:@(2) range:range];

    _textView.needsDisplay = YES;
#endif // INCLUDE_OLD_IM_CODE
}

- (void)unmarkText
{
    ASLogDebug(@"");
    _inputMethodRange = NSMakeRange(0, 0);
    _markedRange = NSMakeRange(NSNotFound, 0);
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
{
    // This method is called when the input manager wants to pop up an
    // auxiliary window.  The position where this should be is controlled by
    // Vim by sending SetPreEditPositionMsgID so compute a position based on
    // the pre-edit (row,column) pair.
    int col = _preeditPoint.col;
    int row = _preeditPoint.row;

    NSFont *font = _textView.markedTextAttributes[NSFontAttributeName];
    if (font == _textView.fontWide) {
        col += _inputMethodRange.location * 2;
        if (col >= _textView.maxSize.col - 1) {
            row += (col / _textView.maxSize.col);
            col = col % 2 ? col % _textView.maxSize.col + 1 :
                            col % _textView.maxSize.col;
        }
    } else {
        col += _inputMethodRange.location;
        if (col >= _textView.maxSize.col) {
            row += (col / _textView.maxSize.col);
            col = col % _textView.maxSize.col;
        }
    }

    NSRect rect = [_textView rectForRow:row column:col numRows:1 numColumns:range.length];

    // NOTE: If the text view is flipped then 'rect' has its origin in the top
    // left corner of the rect, but the methods below expect it to be in the
    // lower left corner.  Compensate for this here.
    // TODO: Maybe the above method should always return rects where the origin
    // is in the lower left corner?
    if (_textView.isFlipped) rect.origin.y += rect.size.height;

    rect.origin = [_textView convertPoint:rect.origin toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
    rect = [_textView.window convertRectToScreen:rect];
#else
    rect.origin = [_textView.window convertBaseToScreen:rect.origin];
#endif

    return rect;
}

- (void)setInputMethodEnabled:(BOOL)enabled
{
    // This flag corresponds to the (negation of the) 'imd' option.  When
    // enabled changes to the input method are detected and forwarded to the
    // backend. We do not forward changes to the input method, instead we let
    // Vim be in complete control.
    if (_inputSourceASCII) {
        CFRelease(_inputSourceASCII);
        _inputSourceASCII = NULL;
    }
    if (_lastInputSource) {
        CFRelease(_lastInputSource);
        _lastInputSource = NULL;
    }
    if (enabled) {
        // Save current locale input source for use when IM is active and
        // get an ASCII source for use when IM is deactivated (by Vim).
        _inputSourceASCII = TISCopyCurrentASCIICapableKeyboardInputSource();
        NSString *locale = NSLocale.currentLocale.localeIdentifier;
        _lastInputSource = TISCopyInputSourceForLanguage((__bridge CFStringRef)locale);
    }

    _inputMethodEnabled = enabled;
    ASLogDebug(@"IM control %sabled", enabled ? "en" : "dis");
}

- (void)setInputSourceActivated:(BOOL)activated
{
    ASLogDebug(@"Activate IM=%d", activated);

    // HACK: If there is marked text when switching IM it will be inserted as
    // normal text.  To avoid this we abandon the marked text before switching.
    [self abandonMarkedText];

    _inputSourceActivated = activated;

    // Enable IM: switch back to input source used when IM was last on
    // Disable IM: switch back to ASCII input source (set in setImControl:)
    TISInputSourceRef source = activated ? _lastInputSource : _inputSourceASCII;
    if (source) {
        ASLogDebug(@"Change input source: %@", TISGetInputSourceProperty(source, kTISPropertyInputSourceID));
        TISSelectInputSource(source);
    }
}

- (BOOL)inlineInputMethodUsed
{
#ifdef INCLUDE_OLD_IM_CODE
    return [NSUserDefaults.standardUserDefaults boolForKey:MMUseInlineImKey];
#else
    return YES;
#endif // INCLUDE_OLD_IM_CODE
}

- (void)normalizeInputMethodState
{
    if (!_inputMethodEnabled) return;

    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    const BOOL activated = !KeyboardInputSourcesEqual(_inputSourceASCII, source);
    const BOOL changed = !KeyboardInputSourcesEqual(_lastInputSource, source);
    if (activated && changed) {
        // Remember current input source so we can switch back to it
        // when IM is once more enabled.
        ASLogDebug(@"Remember last input source: %@", TISGetInputSourceProperty(source, kTISPropertyInputSourceID));
        if (_lastInputSource) CFRelease(_lastInputSource);
        _lastInputSource = source;
    } else {
        CFRelease(source);
    }

    if (_inputSourceActivated != activated) {
        _inputSourceActivated = activated;
        const int msgid = activated ? ActivatedImMsgID : DeactivatedImMsgID;
        [self.vimController sendMessage:msgid data:nil];
    }
}

- (MMWindowController *)windowController
{
    id windowController = _textView.window.windowController;
    if ([windowController isKindOfClass:MMWindowController.class])
        return (MMWindowController *)windowController;
    return nil;
}

- (MMVimController *)vimController
{
    return self.windowController.vimController;
}

- (void)doKeyDown:(NSString *)key
{
    if (!_currentEvent) {
        ASLogDebug(@"No current event; ignore key");
        return;
    }

    const char *chars = key.UTF8String;
    const unsigned length = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    const unsigned code = _currentEvent.keyCode;
    unsigned flags = _currentEvent.modifierFlags;

    // The low 16 bits are not used for modifier flags by NSEvent.  Use
    // these bits for custom flags.
    flags &= NSEventModifierFlagDeviceIndependentFlagsMask;
    if (_currentEvent.isARepeat) flags |= 1;

    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&flags length:sizeof(flags)];
    [data appendBytes:&code length:sizeof(code)];
    [data appendBytes:&length length:sizeof(length)];
    if (length != 0) [data appendBytes:chars length:length];

    [self.vimController sendMessage:KeyDownMsgID data:data];
}

- (void)doInsertText:(NSString *)text
{
    const unsigned length = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (0 == length)
        return;

    unsigned keyCode = 0;
    unsigned flags = 0;

    // HACK! insertText: can be called from outside a keyDown: event in which
    // case _currentEvent is nil.  This happens e.g. when the "Special
    // Characters" palette is used to insert text.  In this situation we assume
    // that the key is not a repeat (if there was a palette that did auto
    // repeat of input we might have to rethink this).
    if (_currentEvent) {
        // HACK! Keys on the numeric key pad are treated as special keys by Vim
        // so we need to pass on key code and modifier flags in this situation.
        const unsigned mods = _currentEvent.modifierFlags;
        if (mods & NSEventModifierFlagNumericPad) {
            flags = mods & NSEventModifierFlagDeviceIndependentFlagsMask;
            keyCode = _currentEvent.keyCode;
        }
        if (_currentEvent.isARepeat) flags |= 1;
    }

    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&flags length:sizeof(flags)];
    [data appendBytes:&keyCode length:sizeof(keyCode)];
    [data appendBytes:&length length:sizeof(length)];
    [data appendBytes:text.UTF8String length:length];

    [self.vimController sendMessage:KeyDownMsgID data:data];
}

- (void)startDragTimerWithInterval:(NSTimeInterval)t
{
    [NSTimer scheduledTimerWithTimeInterval:t target:self selector:@selector(dragTimerFired:) userInfo:nil repeats:NO];
}

- (void)dragTimerFired:(NSTimer *)timer
{
    // TODO: Autoscroll in horizontal direction?
    static unsigned tick = 1;

    _isAutoscrolling = NO;

    if (_isDragging && (_dragRow < 0 || _dragRow >= _textView.maxSize.row)) {
        // HACK! If the mouse cursor is outside the text area, then send a
        // dragged event.  However, if row&col hasn't changed since the last
        // dragged event, Vim won't do anything (see gui_send_mouse_event()).
        // Thus we fiddle with the column to make sure something happens.
        const int col = _dragColumn + (_dragRow < 0 ? -(tick % 2) : +(tick % 2));
        NSMutableData *data = NSMutableData.new;
        [data appendBytes:&_dragRow length:sizeof(_dragRow)];
        [data appendBytes:&col length:sizeof(col)];
        [data appendBytes:&_dragFlags length:sizeof(_dragFlags)];

        [self.vimController sendMessage:MouseDraggedMsgID data:data];

        _isAutoscrolling = YES;
    }

    if (_isDragging) {
        // Compute timer interval depending on how far away the mouse cursor is
        // from the text view.
        NSRect rect = self.trackingRect;
        float dy = 0;
        if (_dragPoint.y < rect.origin.y) dy = rect.origin.y - _dragPoint.y;
        else if (_dragPoint.y > NSMaxY(rect)) dy = _dragPoint.y - NSMaxY(rect);
        if (dy > MMDragAreaSize) dy = MMDragAreaSize;

        const NSTimeInterval t = MMDragTimerMaxInterval - dy * (MMDragTimerMaxInterval - MMDragTimerMinInterval) / MMDragAreaSize;
        [self startDragTimerWithInterval:t];
    }

    ++tick;
}

- (void)setCursor
{
    static NSCursor *customIbeamCursor = nil;

    if (!customIbeamCursor) {
        // Use a custom Ibeam cursor that has better contrast against dark
        // backgrounds.
        // TODO: Is the hotspot ok?
        NSImage *ibeamImage = [NSImage imageNamed:@"ibeam"];
        if (ibeamImage) {
            customIbeamCursor = [[NSCursor alloc] initWithImage:ibeamImage hotSpot:(NSPoint){
                ibeamImage.size.width * .5f, ibeamImage.size.height * .5f
            }];
        }
        if (!customIbeamCursor) {
            ASLogWarn(@"Failed to load custom Ibeam cursor");
            customIbeamCursor = NSCursor.IBeamCursor;
        }
    }

    // This switch should match mshape_names[] in misc2.c.
    //
    // TODO: Add missing cursor shapes.
    switch (_mouseShape) {
    case 2:
        [customIbeamCursor set];
        break;
    case 3: case 4:
        [NSCursor.resizeUpDownCursor set];
        break;
    case 5: case 6:
        [NSCursor.resizeLeftRightCursor set];
        break;
    case 9:
        [NSCursor.crosshairCursor set];
        break;
    case 10:
        [NSCursor.pointingHandCursor set];
        break;
    case 11:
        [NSCursor.openHandCursor set];
        break;
    default:
        [NSCursor.arrowCursor set];
        break;
    }

    // Shape 1 indicates that the mouse cursor should be hidden.
    if (1 == _mouseShape) NSCursor.hiddenUntilMouseMoves = YES;
}

- (NSRect)trackingRect
{
    NSRect rect = _textView.frame;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    const int left = [defaults integerForKey:MMTextInsetLeftKey];
    const int top = [defaults integerForKey:MMTextInsetTopKey];
    const int right = [defaults integerForKey:MMTextInsetRightKey];
    const int bot = [defaults integerForKey:MMTextInsetBottomKey];

    rect.origin.x = left;
    rect.origin.y = top;
    rect.size.width -= left + right - 1;
    rect.size.height -= top + bot - 1;

    return rect;
}

- (BOOL)inputManagerHandleMouseEvent:(NSEvent *)event
{
    // NOTE: The input manager usually handles events like mouse clicks (e.g.
    // the Kotoeri manager "commits" the text on left clicks).

    if (event) return [NSTextInputContext.currentInputContext handleEvent:event];
    return NO;
}

- (void)sendMarkedText:(NSString *)text position:(int32_t)pos
{
    if (!self.inlineInputMethodUsed) return;

    const unsigned len = !text ? 0 : [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&pos length:sizeof(pos)];
    [data appendBytes:&len length:sizeof(len)];
    if (len != 0) {
        [data appendBytes:text.UTF8String length:len];
        [data appendBytes:"\x00" length:1];
    }

    [self.vimController sendMessage:SetMarkedTextMsgID data:data];
}

- (void)abandonMarkedText
{
    [self unmarkText];

    // Send an empty marked text message with position set to -1 to indicate
    // that the marked text should be abandoned.  (If pos is set to 0 Vim will
    // send backspace sequences to delete the old marked text.)
    [self sendMarkedText:nil position:-1];
    [NSTextInputContext.currentInputContext discardMarkedText];
}

- (void)sendGestureEvent:(int)gesture flags:(int)flags
{
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&flags length:sizeof(flags)];
    [data appendBytes:&gesture length:sizeof(gesture)];

    [self.vimController sendMessage:GestureMsgID data:data];
}

@end
