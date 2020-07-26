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
 * MMCoreTextView
 *
 * Dispatches keyboard and mouse input to the backend.  Handles drag-n-drop of
 * files onto window.  The rendering is done using CoreText.
 *
 * The text view area consists of two parts:
 *   1. The text area - this is where text is rendered; the size is governed by
 *      the current number of rows and columns.
 *   2. The inset area - this is a border around the text area; the size is
 *      governed by the user defaults MMTextInset[Left|Right|Top|Bottom].
 *
 * The current size of the text view frame does not always match the desired
 * area, i.e. the area determined by the number of rows, columns plus text
 * inset.  This distinction is particularly important when the view is being
 * resized.
 */
#import "Miscellaneous.h"
#import "MMAppController.h"
#import "MMCoreTextView.h"
#import "MMCoreTextView+Compatibility.h"
#import "MMFontSmoothing.h"
#import "MMTextViewHelper.h"
#import "MMVimController.h"
#import "MMWindowController.h"
#import "NSAttributedString+CoreText.h"
#import "MMDrawCommand.h"

// TODO: What does DRAW_TRANSP flag do?  If the background isn't drawn when
// this flag is set, then sometimes the character after the cursor becomes
// blank.  Everything seems to work fine by just ignoring this flag.
#define DRAW_TRANSP               0x01    /* draw with transparent bg */
#define DRAW_BOLD                 0x02    /* draw bold text */
#define DRAW_UNDERL               0x04    /* draw underline text */
#define DRAW_UNDERC               0x08    /* draw undercurl text */
#define DRAW_ITALIC               0x10    /* draw italic text */
#define DRAW_CURSOR               0x20
#define DRAW_WIDE                 0x80    /* draw wide text */
#define DRAW_COMP                 0x100   /* drawing composing char */


@interface MMCoreTextView (Drawing)
- (NSRect)rectFromRow:(int)row1 column:(int)col1 toRow:(int)row2 column:(int)col2;
- (void)batchDrawData:(NSData *)data;
- (void)drawAttributedString:(NSAttributedString *)attributedString atRow:(int)row column:(int)col cells:(int)cells withFlags:(int)flags foregroundColor:(int)fg backgroundColor:(int)bg specialColor:(int)sp;
- (void)deleteLinesFromRow:(int)row lineCount:(int)count scrollBottom:(int)bottom left:(int)left right:(int)right color:(int)color;
- (void)insertLinesAtRow:(int)row lineCount:(int)count scrollBottom:(int)bottom left:(int)left right:(int)right color:(int)color;
- (void)clearBlockFromRow:(int)row1 column:(int)col1 toRow:(int)row2 column:(int)col2 color:(int)color;
- (void)clearAll;
- (void)drawInsertionPointAtRow:(int)row column:(int)col shape:(int)shape fraction:(int)percent color:(int)color;
- (void)drawInvertedRectAtRow:(int)row column:(int)col numRows:(int)nrows numColumns:(int)ncols;
- (void)clearBlockWithParams:(const MMDrawCommandClear *)params;
- (void)deleteLinesWithParams:(const MMDrawCommandDeleteLines *)params;
#if 0
#undef ASLogNotice
#define ASLogNotice(format, ...) NSLog(format, ##__VA_ARGS__)
#else
#undef ASLogNotice
#define ASLogNotice(format, ...)
#endif
@end

@interface MMCoreTextView (ToolTip)
- (void)_sendToolTipMouseEntered;
- (void)_sendToolTipMouseExited;
@end

static float
defaultLineHeightForFont(NSFont *font)
{
    // HACK: -[NSFont defaultLineHeightForFont] is deprecated but since the
    // CoreText renderer does not use NSLayoutManager we create one
    // temporarily.
    return [NSLayoutManager.new defaultLineHeightForFont:font];
}

static double
defaultAdvanceForFont(NSFont *font)
{
    const CGFloat pointSize = roundf(font.pointSize);
    CTFontDescriptorRef fontDescriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{
        (NSString *)kCTFontNameAttribute: font.displayName,
        (NSString *)kCTFontSizeAttribute: @(pointSize),
    });
    CTFontRef fontRef = CTFontCreateWithFontDescriptor(fontDescriptor, pointSize, NULL);
    CFRelease(fontDescriptor);
    NSFont *newFont = (__bridge_transfer NSFont*)fontRef;

    // NOTE: Previously we used CTFontGetAdvancesForGlyphs() to get the advance
    // for 'm' but this sometimes returned advances that were too small making
    // the font spacing look too tight.
    // Instead use the same method to query the width of 'm' as MMTextStorage
    // uses to make things consistent across renderers.
    return [@"m" sizeWithAttributes:@{NSFontAttributeName: newFont}].width;
}

@implementation MMCoreTextView {
    float               _fontDescent;
    NSMutableArray      *_drawData;
    MMTextViewHelper    *_helper;
    unsigned            _maxlen;
    CGGlyph             *_glyphs;
    CGPoint             *_positions;
    NSMutableArray      *_fontCache;
    CGLayerRef          _CGLayer;
    CGContextRef        _CGLayerContext;
    NSLock              *_CGLayerLock;
    NSMutableData       *_characters;
    BOOL                _drawPending;
}

@synthesize maxSize = _maxSize, cellSize = _cellSize,
    defaultForegroundColor = _defaultForegroundColor, defaultBackgroundColor = _defaultBackgroundColor,
    font = _font, fontWide = _fontWide,
    linespace = _linespace, columnspace = _columnspace, textContainerInset = _textContainerInset,
    antialias = _antialias, ligatures = _ligatures, thinStrokes = _thinStrokes,
    CGLayerEnabled = _CGLayerEnabled,
    IMActivated = _IMActivated, IMControlled = _IMControlled;
@dynamic mouseShape, markedTextAttributes;

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]) == nil) return nil;

    _CGLayerEnabled = [NSUserDefaults.standardUserDefaults boolForKey:MMUseCGLayerAlwaysKey];
    _CGLayerLock = NSLock.new;

    // NOTE!  It does not matter which font is set here, Vim will set its
    // own font on startup anyway.  Just set some bogus values.
    _font = [NSFont userFixedPitchFontOfSize:0];
    _cellSize = (CGSize){1, 1};

    // NOTE: If the default changes to 'NO' then the intialization of
    // p_antialias in option.c must change as well.
    _antialias = YES;

    _drawData = NSMutableArray.new;
    _fontCache = NSMutableArray.new;
    _characters = NSMutableData.new;
    _helper = MMTextViewHelper.new;
    _helper.textView = self;

    [self registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];

    return self;
}

- (void)dealloc
{
    _helper.textView = nil;

    if (_glyphs) {
        free(_glyphs);
        _glyphs = NULL;
    }
    if (_positions) {
        free(_positions);
        _positions = NULL;
    }
}

- (void)setDefaultColorsBackground:(NSColor *)bg foreground:(NSColor *)fg
{
    if (_defaultBackgroundColor != bg) _defaultBackgroundColor = bg;

    // NOTE: The default foreground color isn't actually used for anything, but
    // other class instances might want to be able to access it so it is stored
    // here.
    if (_defaultForegroundColor != fg) _defaultForegroundColor = fg;
}

- (NSRect)rectForRowsInRange:(NSRange)range
{
    // Compute rect whose vertical dimensions cover the rows in the given
    // range.
    // NOTE: The rect should be in _flipped_ coordinates and the first row must
    // include the top inset as well.  (This method is only used to place the
    // scrollbars inside MMVimView.)

    NSRect rect = NSZeroRect;
    const NSUInteger start = (range.location > _maxSize.row) ? _maxSize.row : range.location;
    const NSUInteger length = (start + range.length > _maxSize.row) ? _maxSize.row - start : range.length;

    if (start > 0) {
        rect.origin.y = _cellSize.height * start + _textContainerInset.height;
        rect.size.height = _cellSize.height * length;
    } else {
        rect.size.height = _cellSize.height * length + _textContainerInset.height;
    }

    return rect;
}

- (NSRect)rectForColumnsInRange:(NSRange)range
{
    // Compute rect whose horizontal dimensions cover the columns in the given
    // range.
    // NOTE: The first column must include the left inset.  (This method is
    // only used to place the scrollbars inside MMVimView.)

    NSRect rect = NSZeroRect;
    unsigned start = range.location > _maxSize.col ? _maxSize.col : range.location;
    unsigned length = range.length;

    if (start + length > _maxSize.col) length = _maxSize.col - start;

    if (start > 0) {
        rect.origin.x = _cellSize.width * start + _textContainerInset.width;
        rect.size.width = _cellSize.width * length;
    } else {
        // Include left inset
        rect.origin.x = 0;
        rect.size.width = _cellSize.width * length + _textContainerInset.width;
    }

    return rect;
}

- (void)setFont:(NSFont *)newFont
{
    if (newFont == _font) return;

    const CGFloat emSize = roundf(defaultAdvanceForFont(newFont));
    const CGFloat pointSize = roundf(newFont.pointSize);
    const CGFloat multiplier = [NSUserDefaults.standardUserDefaults floatForKey:MMCellWidthMultiplierKey];
    const CGFloat width = _columnspace + ceilf(emSize * multiplier);

    CTFontDescriptorRef fontDescriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{
        (NSString *)kCTFontNameAttribute: newFont.displayName,
        (NSString *)kCTFontSizeAttribute: @(pointSize),
        (NSString *)kCTFontFixedAdvanceAttribute: @(width),
    });
    CTFontRef fontRef = CTFontCreateWithFontDescriptor(fontDescriptor, pointSize, NULL);
    CFRelease(fontDescriptor);

    _font = (__bridge_transfer NSFont*)fontRef;

    // NOTE! Even though NSFontFixedAdvanceAttribute is a float, it will
    // only render at integer sizes.  Hence, we restrict the cell width to
    // an integer here, otherwise the window width and the actual text
    // width will not match.
    _cellSize.width = width;
    _cellSize.height = _linespace + defaultLineHeightForFont(_font);

    _fontDescent = ceil(CTFontGetDescent(fontRef));

    [_fontCache removeAllObjects];
}

- (void)setFontWide:(NSFont *)newFont
{
    if (!newFont) {
        // Use the normal font as the wide font (note that the normal font may
        // very well include wide characters.)
        if (_font) [self setFontWide:_font];
    } else if (newFont != _fontWide) {
        // NOTE: No need to set point size etc. since this is taken from the
        // regular font when drawing.
        _fontWide = nil;

        const CGFloat width = _cellSize.width * 2;
        NSFontDescriptor *fontDescriptor = [newFont.fontDescriptor fontDescriptorByAddingAttributes:@{
            NSFontFixedAdvanceAttribute: @(width)
        }];

        // Use 'Apple Color Emoji' font for rendering emoji
        const CGFloat size = newFont.pointSize > _font.pointSize ? _font.pointSize : newFont.pointSize;
        NSFontDescriptor *emoji = [NSFontDescriptor fontDescriptorWithName:@"Apple Color Emoji" size:size];
        emoji = [emoji fontDescriptorByAddingAttributes:@{
            NSFontFixedAdvanceAttribute: @(width)
        }];
        NSFontDescriptor *merged = [emoji fontDescriptorByAddingAttributes:@{
            NSFontCascadeListAttribute: @[fontDescriptor],
            NSFontFixedAdvanceAttribute: @(width)
        }];
        _fontWide = [NSFont fontWithDescriptor:merged size:_font.pointSize];
    }
}

- (void)setLinespace:(float)value
{
    _linespace = value;

    // NOTE: The linespace is added to the cell height in order for a multiline
    // selection not to have white (background color) gaps between lines.  Also
    // this simplifies the code a lot because there is no need to check the
    // linespace when calculating the size of the text view etc.  When the
    // linespace is non-zero the baseline will be adjusted as well; check
    // MMTypesetter.
    _cellSize.height = _linespace + defaultLineHeightForFont(_font);
}

- (void)setColumnspace:(float)value
{
    _columnspace = value;

    const double em = round(defaultAdvanceForFont(_font));
    const float multiplier =
        [NSUserDefaults.standardUserDefaults floatForKey:MMCellWidthMultiplierKey];

    _cellSize.width = _columnspace + ceil(em * multiplier);

    NSFont *font = _font.copy;
    _font = nil;
    self.font = font;
}

- (void)deleteSign:(NSString *)signName
{
    [_helper deleteImage:signName];
}

- (void)setShouldDrawInsertionPoint:(BOOL)on
{
}

- (void)setPreEditRow:(int)row column:(int)col
{
    _helper.preeditPoint = (MMPoint){row, col};
}

- (void)setMouseShape:(int)shape
{
    _helper.mouseShape = shape;
}

- (void)setIMControlled:(BOOL)enable
{
    _IMControlled = enable;
    _helper.inputMethodEnabled = enable;
}

- (void)setIMActivated:(BOOL)enable
{
    _IMActivated = enable;
    _helper.inputSourceActivated = enable;
}

- (void)checkImState
{
    [_helper normalizeInputMethodState];
}

- (BOOL)_wantsKeyDownForEvent:(id)event
{
    // HACK! This is an undocumented method which is called from within
    // -[NSWindow sendEvent] (and perhaps in other places as well) when the
    // user presses e.g. Ctrl-Tab or Ctrl-Esc .  Returning YES here effectively
    // disables the Cocoa "key view loop" (which is undesirable).  It may have
    // other side-effects, but we really _do_ want to process all key down
    // events so it seems safe to always return YES.
    return YES;
}

- (void)keyDown:(NSEvent *)event
{
    [_helper keyDown:event];
}

- (void)insertText:(id)string
{
    [_helper insertText:string];
}

- (void)doCommandBySelector:(SEL)selector
{
    [_helper doCommandBySelector:selector];
}

- (BOOL)hasMarkedText
{
    return [_helper hasMarkedText];
}

- (NSRange)markedRange
{
    return [_helper markedRange];
}

- (NSDictionary *)markedTextAttributes
{
    return [_helper markedTextAttributes];
}

- (void)setMarkedTextAttributes:(NSDictionary *)attr
{
    [_helper setMarkedTextAttributes:attr];
}

- (void)setMarkedText:(id)text selectedRange:(NSRange)range
{
    [_helper setMarkedText:text selectedRange:range];
}

- (void)unmarkText
{
    [_helper unmarkText];
}

- (void)scrollWheel:(NSEvent *)event
{
    [_helper scrollWheel:event];
}

- (void)mouseDown:(NSEvent *)event
{
    [_helper mouseDown:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    [_helper mouseDown:event];
}

- (void)otherMouseDown:(NSEvent *)event
{
    [_helper mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event
{
    [_helper mouseUp:event];
}

- (void)rightMouseUp:(NSEvent *)event
{
    [_helper mouseUp:event];
}

- (void)otherMouseUp:(NSEvent *)event
{
    [_helper mouseUp:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    [_helper mouseDragged:event];
}

- (void)rightMouseDragged:(NSEvent *)event
{
    [_helper mouseDragged:event];
}

- (void)otherMouseDragged:(NSEvent *)event
{
    [_helper mouseDragged:event];
}

- (void)mouseMoved:(NSEvent *)event
{
    [_helper mouseMoved:event];
}

- (void)swipeWithEvent:(NSEvent *)event
{
    [_helper swipeWithEvent:event];
}

- (void)pressureChangeWithEvent:(NSEvent *)event
{
    [_helper pressureChangeWithEvent:event];
}

- (NSMenu*)menuForEvent:(NSEvent *)event
{
    // HACK! Return nil to disable default popup menus (Vim provides its own).
    // Called when user Ctrl-clicks in the view (this is already handled in
    // rightMouseDown:).
    return nil;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    return [_helper performDragOperation:sender];
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    return [_helper draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return [_helper draggingUpdated:sender];
}

- (BOOL)mouseDownCanMoveWindow
{
    return NO;
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)isFlipped
{
    return NO;
}

- (void)drawRect:(NSRect)rect
{
    NSGraphicsContext.currentContext.shouldAntialias = _antialias;

    if (_CGLayerEnabled && _drawData.count == 0) {
        // during a live resize, we will have around a stale layer until the
        // refresh messages travel back from the vim process. We push the old
        // layer in at an offset to get rid of jitter due to lines changing
        // position.
        [_CGLayerLock lock];
        CGLayerRef layerRef = [self getCGLayer];
        const CGSize size = CGLayerGetSize(layerRef);
        const NSRect drawRect = {{0, self.frame.size.height - size.height}, size};

        CGContextRef context = NSGraphicsContext.currentContext.graphicsPort;

        const NSRect *rects = nil;
        NSInteger count = 0;
        [self getRectsBeingDrawn:&rects count:&count];

        CGContextSaveGState(context);
        CGContextClipToRects(context, rects, count);
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawLayerInRect(context, drawRect, layerRef);
        CGContextRestoreGState(context);

        [_CGLayerLock unlock];
        return;
    }
    for (NSData *data in _drawData.objectEnumerator) {
        [self batchDrawData:data];
    }
    [_drawData removeAllObjects];
}

- (void)performBatchDrawWithData:(NSData *)data
{
    if (_CGLayerEnabled && _drawData.count == 0 && [self getCGContext]) {
        [_CGLayerLock lock];
        [self batchDrawData:data];
        [_CGLayerLock unlock];
    } else {
        [_drawData addObject:data];
        self.needsDisplay = YES;
    }
    if (_drawPending) {
        [NSAnimationContext endGrouping];
        _drawPending = NO;
    }
}

- (void)setCGLayerEnabled:(BOOL)enabled
{
    _CGLayerEnabled = enabled;

    if (!_CGLayerEnabled)
        [self releaseCGLayer];
}

- (void)releaseCGLayer
{
    if (_CGLayer)  {
        CGLayerRelease(_CGLayer);
        _CGLayer = NULL;
        _CGLayerContext = NULL;
    }
}

- (CGLayerRef)getCGLayer
{
    NSParameterAssert(_CGLayerEnabled);
    if (!_CGLayer && [self lockFocusIfCanDraw]) {
        _CGLayer = CGLayerCreateWithContext(NSGraphicsContext.currentContext.graphicsPort, self.frame.size, NULL);
        [self unlockFocus];
    }
    return _CGLayer;
}

- (CGContextRef)getCGContext
{
    if (_CGLayerEnabled) {
        if (!_CGLayerContext) _CGLayerContext = CGLayerGetContext([self getCGLayer]);
        return _CGLayerContext;
    } else {
        return NSGraphicsContext.currentContext.graphicsPort;
    }
}

- (void)setNeedsDisplayCGLayerInRect:(CGRect)rect
{
    if (_CGLayerEnabled) self.needsDisplayInRect = rect;
}

- (void)setNeedsDisplayCGLayer:(BOOL)needs
{
    if (_CGLayerEnabled) self.needsDisplay = needs;
}

- (NSSize)constrainRows:(int *)rows columns:(int *)cols toSize:(NSSize)size
{
    // TODO:
    // - Rounding errors may cause size change when there should be none
    // - Desired rows/columns shold not be 'too small'

    // Constrain the desired size to the given size.  Values for the minimum
    // rows and columns are taken from Vim.
    NSSize desiredSize = self.desiredSize;
    NSInteger desiredRows = _maxSize.row;
    NSInteger desiredCols = _maxSize.col;

    if (size.height != desiredSize.height) {
        const NSInteger inset = [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetBottomKey];
        const CGFloat fh = MAX(_cellSize.height, 1);
        const CGFloat ih = _textContainerInset.height + inset;

        desiredRows = floor((size.height - ih) / fh);
        desiredSize.height = fh * desiredRows + ih;
    }

    if (size.width != desiredSize.width) {
        const NSInteger inset = [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetRightKey];
        const CGFloat fw = MAX(_cellSize.width, 1);
        const CGFloat iw = _textContainerInset.width + inset;

        desiredCols = floor((size.width - iw) / fw);
        desiredSize.width = fw * desiredCols + iw;
    }

    if (rows) *rows = (int)desiredRows;
    if (cols) *cols = (int)desiredCols;

    return desiredSize;
}

- (NSSize)desiredSize
{
    // Compute the size the text view should be for the entire text area and
    // inset area to be visible with the present number of rows and columns.
    const NSInteger right = [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetRightKey];
    const NSInteger bottom = [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetBottomKey];

    return NSMakeSize(_maxSize.col * _cellSize.width + _textContainerInset.width + right,
                      _maxSize.row * _cellSize.height + _textContainerInset.height + bottom);
}

- (NSSize)minSize
{
    // Compute the smallest size the text view is allowed to be.
    const NSInteger right = [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetRightKey];
    const NSInteger bottom = [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetBottomKey];

    return NSMakeSize(MMMinColumns * _cellSize.width + _textContainerInset.width + right,
                      MMMinRows * _cellSize.height + _textContainerInset.height + bottom);
}

- (void)changeFont:(id)sender
{
    NSFont *newFont = [sender convertFont:_font];

    if (newFont) {
        unsigned length = [newFont.fontName lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (length != 0) {
            NSMutableData *data = NSMutableData.new;

            // pointSize
            const float pointSize = newFont.pointSize;
            [data appendBytes:&pointSize length:sizeof(pointSize)];

            // displayName
            ++length;  // include NUL byte
            [data appendBytes:&length length:sizeof(length)];
            [data appendBytes:newFont.displayName.UTF8String length:length];

            [self.vimController sendMessage:SetFontMsgID data:data];
        }
    }
}

//
// NOTE: The menu items cut/copy/paste/undo/redo/select all/... must be bound
// to the same actions as in IB otherwise they will not work with dialogs.  All
// we do here is forward these actions to the Vim process.
//
- (IBAction)cut:(id)sender
{
    [self.windowController vimMenuItemAction:sender];
}

- (IBAction)copy:(id)sender
{
    [self.windowController vimMenuItemAction:sender];
}

- (IBAction)paste:(id)sender
{
    [self.windowController vimMenuItemAction:sender];
}

- (IBAction)undo:(id)sender
{
    [self.windowController vimMenuItemAction:sender];
}

- (IBAction)redo:(id)sender
{
    [self.windowController vimMenuItemAction:sender];
}

- (IBAction)selectAll:(id)sender
{
    [self.windowController vimMenuItemAction:sender];
}

- (BOOL)convertPoint:(NSPoint)point toRow:(int *)row column:(int *)column
{
    point.y = self.bounds.size.height - point.y;

    const NSPoint origin = {_textContainerInset.width, _textContainerInset.height};

    if (!(_cellSize.width > 0 && _cellSize.height > 0)) return NO;

    if (row) *row = floor((point.y - origin.y - 1) / _cellSize.height);
    if (column) *column = floor((point.x - origin.x - 1) / _cellSize.width);

    return YES;
}

- (NSRect)rectForRow:(int)row column:(int)col numRows:(int)nr numColumns:(int)nc
{
    // Return the rect for the block which covers the specified rows and
    // columns.  The lower-left corner is the origin of this rect.
    // NOTE: The coordinate system is _NOT_ flipped!
    return (NSRect){
        .origin.x = col * _cellSize.width + _textContainerInset.width,
        .origin.y = self.bounds.size.height - (row + nr)*_cellSize.height - _textContainerInset.height,
        .size.width = nc * _cellSize.width,
        .size.height = nr * _cellSize.height,
    };
}

- (NSArray *)validAttributesForMarkedText
{
    return nil;
}

- (NSAttributedString *)attributedSubstringFromRange:(NSRange)range
{
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    return NSNotFound;
}

- (NSInteger)conversationIdentifier
{
    return (NSInteger)self;
}

- (NSRange)selectedRange
{
    return _helper.inputMethodRange;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
{
    return [_helper firstRectForCharacterRange:range];
}

- (MMWindowController *)windowController
{
    id windowController = self.window.windowController;
    if ([windowController isKindOfClass:MMWindowController.class])
        return (MMWindowController*)windowController;
    return nil;
}

- (MMVimController *)vimController
{
    return self.windowController.vimController;
}

- (void)setWideFont:(NSFont *)font
{
    self.fontWide = font;
}

// Sets the view's current tooltip, to be displayed at the current mouse
// location. (This does not make the tooltip appear -- as usual, it only
// appears after a delay.) Pass null to remove the tooltip.
- (void)setToolTipAtMousePoint:(NSString *)string
{
    // If the mouse is outside the view, then clear the tooltip (otherwise the
    // tooltip may appear outside the view which looks weird!).
    const NSPoint pt = [self.window mouseLocationOutsideOfEventStream];
    if (!NSMouseInRect([self convertPoint:pt fromView:nil], self.frame, NO))
        string = nil;

    NSString *toolTip = string.length == 0 ? nil : string;
    NSString *oldToolTip = _toolTip;
    if ((!toolTip || !oldToolTip) ? toolTip == oldToolTip : [toolTip isEqualToString:oldToolTip]) {
        return;
    }
    if (oldToolTip) {
        [self _sendToolTipMouseExited];
    }
    _toolTip = toolTip.copy;
    if (toolTip) {
        // See radar 3500217 for why we remove all tooltips
        // rather than just the single one we created.
        [self removeAllToolTips];
        const NSRect wideOpenRect = NSMakeRect(-100000, -100000, 200000, 200000);
        _lastToolTipTag = [self addToolTipRect:wideOpenRect owner:self userData:nil];
        [self _sendToolTipMouseEntered];
    }
}

- (void)setFrameSize:(NSSize)newSize
{
    if (!_drawPending && !NSEqualSizes(newSize, self.frame.size) && _drawData.count == 0) {
        [NSAnimationContext beginGrouping];
        _drawPending = YES;
    }
    [super setFrameSize:newSize];
}

@end

/**
 */
@implementation MMCoreTextView (Drawing)

- (NSRect)rectFromRow:(int)row1 column:(int)col1 toRow:(int)row2 column:(int)col2
{
    return (NSRect){
        .origin.x = _textContainerInset.width + col1 * _cellSize.width,
        .origin.y = self.bounds.size.height - _textContainerInset.height - (row2 + 1) * _cellSize.height,
        .size.width = (col2 + 1 - col1) * _cellSize.width,
        .size.height = (row2 + 1 - row1) * _cellSize.height
    };
}

- (void)batchDrawData:(NSData *)data
{
    const void *bytes = data.bytes;
    const void *const end = bytes + data.length;

    ASLogNotice(@"====> BEGIN");

    while (bytes < end) {
        MMDrawCommand *command = [[MMDrawCommand alloc] initWithBytes:bytes];
        switch (command.type) {
        case ClearAllDrawType: [self clearAll]; break;
        case ClearBlockDrawType: [self clearBlockWithParams:command.parametersForClear]; break;
        case DeleteLinesDrawType: [self deleteLinesWithParams:command.parametersForDeleteLines]; break;
        case DrawStringDrawType: [self drawStringWithParams:command.parametersForDrawString]; break;
        case InsertLinesDrawType: [self insertLinesWithParams:command.parametersForInsertLines]; break;
        case DrawCursorDrawType: [self drawCursorWithParams:command.parametersForDrawCursor]; break;
        case SetCursorPosDrawType: [self moveCursorWithParams:command.parametersForMoveCursor]; break;
        case DrawInvertedRectDrawType: [self drawInvertedRectWithParams:command.parametersForInvertRect]; break;
        case DrawSignDrawType: [self drawSignWithParams:command.parametersForDrawSign]; break;
        default: ASLogWarn(@"Unknown draw type (type=%d)", command.type); break;
        }
        bytes += command.byteCount;
    }

    ASLogNotice(@"<==== END");
}

- (void)drawString:(NSString *)string row:(int)row column:(int)col cells:(int)cells flags:(int)flags fg:(int)fg bg:(int)bg sp:(int)sp
{
    NSMutableDictionary *attributes = @{
        NSFontAttributeName: [self fontWithFlags:flags],
        NSLigatureAttributeName: (_ligatures ? @1 : @0),
        NSKernAttributeName: @0,
        NSForegroundColorAttributeName: [NSColor colorWithDeviceRed:RED(fg) green:GREEN(fg) blue:BLUE(fg) alpha:ALPHA(fg)]
    }.mutableCopy;

    if (flags & DRAW_UNDERL) {
        attributes[NSUnderlineColorAttributeName] = [NSColor colorWithDeviceRed:RED(sp) green:GREEN(sp) blue:BLUE(sp) alpha:ALPHA(sp)];
        attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }

    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:string attributes:attributes.copy];
    [self drawAttributedString:attributedString atRow:row column:col cells:cells withFlags:flags foregroundColor:fg backgroundColor:bg specialColor:sp];
}

- (void)drawAttributedString:(NSAttributedString *)attributedString atRow:(int)row column:(int)col cells:(int)cells withFlags:(int)flags foregroundColor:(int)fg backgroundColor:(int)bg specialColor:(int)sp
{
    CGContextRef context = [self getCGContext];
    const CGPoint origin = {
        .x = col * _cellSize.width + _textContainerInset.width,
        .y = self.bounds.size.height - _textContainerInset.height - (row + 1) * _cellSize.height,
    };

    // NOTE: It is assumed that either all characters in 'chars' are wide or
    // all are normal width.
    const CGFloat charWidth = _cellSize.width * (flags & DRAW_WIDE ? 2 : 1);

    // NOTE!  'cells' is zero if we're drawing a composing character
    const CGRect clipRect = {origin, {cells > 0 ? cells * _cellSize.width : charWidth, _cellSize.height}};

    CGContextSaveGState(context);
    {
        MMFontSmoothing *fontSmoothing = [MMFontSmoothing fontSmoothingEnabled:_thinStrokes on:context];

        CGContextClipToRect(context, clipRect);
        if (!(flags & DRAW_TRANSP)) {
            [self drawOn:context backgroundAt:origin stride:cells color:bg];
        }
        if (!(flags & DRAW_UNDERL) && (flags & DRAW_UNDERC)) {
            [self drawOn:context curlyUnderlineAt:origin stride:cells color:sp];
        }

        [attributedString drawAtPoint:(CGPoint){origin.x, origin.y + _fontDescent} on:context];

        [fontSmoothing restore];
    }
    CGContextRestoreGState(context);

    [self setNeedsDisplayCGLayerInRect:clipRect];
}

- (void)drawOn:(CGContextRef)context backgroundAt:(CGPoint)point stride:(int)stride color:(int)color
{
    // Draw the background of the text.  Note that if we ignore the
    // DRAW_TRANSP flag and always draw the background, then the insert
    // mode cursor is drawn over.
    CGContextSetRGBFillColor(context, RED(color), GREEN(color), BLUE(color), ALPHA(color));

    // Antialiasing may cause bleeding effects which are highly undesirable
    // when clearing the background (this code is also called to draw the
    // cursor sometimes) so disable it temporarily.
    CGContextSetShouldAntialias(context, NO);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextFillRect(context, (CGRect){point, {stride * _cellSize.width, _cellSize.height}});
    CGContextSetShouldAntialias(context, _antialias);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
}

- (void)drawOn:(CGContextRef)context underlineAt:(CGPoint)point stride:(int)stride color:(int)color
{
    CGContextSetRGBFillColor(context, RED(color), GREEN(color), BLUE(color), ALPHA(color));
    CGContextFillRect(context, (CGRect){{point.x, point.y + 0.4 * _fontDescent}, {stride * _cellSize.width, 1}});
}

- (void)prepareGlyphsWithCount:(UniCharCount)count charWidth:(CGFloat)charWidth
{
    if (count > _maxlen) {
        if (_glyphs) free(_glyphs);
        if (_positions) free(_positions);
        _glyphs = (CGGlyph *)malloc(count * sizeof(CGGlyph));
        _positions = (CGPoint *)calloc(count, sizeof(CGPoint));
        _maxlen = count;
    }
    // Calculate position of each glyph relative to (x,y).
    CGFloat xrel = 0;
    for (UniCharCount i = 0; i < count; ++i, xrel += charWidth) {
        _positions[i].x = xrel;
    }
}

- (NSFont *)fontWithFlags:(int)flags
{
    CTFontRef fontRef = (__bridge_retained CTFontRef)(flags & DRAW_WIDE ? _fontWide : _font);

    CTFontSymbolicTraits traits = 0;
    if (flags & DRAW_ITALIC) traits |= kCTFontItalicTrait;
    if (flags & DRAW_BOLD) traits |= kCTFontBoldTrait;
    if (traits) {
        CTFontRef traitedRef = CTFontCreateCopyWithSymbolicTraits(fontRef, 0, NULL, traits, traits);
        if (traitedRef) {
            CFRelease(fontRef);
            fontRef = traitedRef;
        }
    }

    return (__bridge_transfer NSFont *)fontRef;
}

- (void)drawOn:(CGContextRef)context curlyUnderlineAt:(CGPoint)point stride:(int)stride color:(int)color
{
    CGFloat x0 = point.x;
    const CGFloat y0 = point.y + 1, cw = _cellSize.width, h = 0.5 * _fontDescent;
    const CGFloat sw = 0.25 * cw;
    const CGFloat mw = 0.5 * cw;
    const CGFloat lw = 0.75 * cw;

    CGContextMoveToPoint(context, x0, y0);
    for (int k = 0; k < stride; ++k) {
        CGContextAddCurveToPoint(context, x0 + sw, y0 + 0, x0 + sw, y0 + h, x0 + mw, y0 + h);
        CGContextAddCurveToPoint(context, x0 + lw, y0 + h, x0 + lw, y0 + 0, x0 + cw, y0 + 0);
        x0 += cw;
    }

    CGContextSetRGBStrokeColor(context, RED(color), GREEN(color), BLUE(color), ALPHA(color));
    CGContextStrokePath(context);
}

- (void)scrollRect:(NSRect)rect lineCount:(int)count
{
    if (_CGLayerEnabled) {
        CGContextRef context = [self getCGContext];
        int yOffset = count * _cellSize.height;
        NSRect clipRect = rect;
        clipRect.origin.y -= yOffset;

        // draw self on top of self, offset so as to "scroll" lines vertically
        CGContextSaveGState(context);
        CGContextClipToRect(context, clipRect);
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawLayerAtPoint(context, (CGPoint){0, -yOffset}, [self getCGLayer]);
        CGContextRestoreGState(context);
        self.needsDisplayCGLayerInRect = clipRect;
    } else {
        [self scrollRect:rect by:(NSSize){0, -count * _cellSize.height}];
    }
}

- (void)deleteLinesWithParams:(const MMDrawCommandDeleteLines *)p
{
    ASLogNotice(@"   Delete %d line(s) from %d", p->count, p->row);
    [self deleteLinesFromRow:p->row lineCount:p->count scrollBottom:p->scrollBottom left:p->left right:p->right color:p->color];
}

- (void)deleteLinesFromRow:(int)row lineCount:(int)count scrollBottom:(int)bottom left:(int)left right:(int)right color:(int)color
{
    const NSRect rect = [self rectFromRow:row + count column:left toRow:bottom column:right];

    // move rect up for count lines
    [self scrollRect:rect lineCount:-count];
    [self clearBlockFromRow:bottom - count + 1 column:left toRow:bottom column:right color:color];
}

- (void)insertLinesAtRow:(int)row lineCount:(int)count scrollBottom:(int)bottom left:(int)left right:(int)right color:(int)color
{
    const NSRect rect = [self rectFromRow:row column:left toRow:bottom - count column:right];

    // move rect down for count lines
    [self scrollRect:rect lineCount:count];
    [self clearBlockFromRow:row column:left toRow:row + count - 1 column:right color:color];
}

- (void)insertLinesWithParams:(const MMDrawCommandInsertLines *)p
{
    ASLogNotice(@"   Insert %d line(s) at row %d", p->count, p->row);
    [self insertLinesAtRow:p->row lineCount:p->count scrollBottom:p->scrollBottom left:p->left right:p->right color:p->color];
}

- (void)clearBlockWithParams:(const MMDrawCommandClear *)p
{
    ASLogNotice(@"   Clear block (%d,%d) -> (%d,%d)", p->row1, p->col1, p->row2, p->col2);

    [self clearBlockFromRow:p->row1 column:p->col1 toRow:p->row2 column:p->col2 color:p->color];
}

- (void)clearBlockFromRow:(int)row1 column:(int)col1 toRow:(int)row2 column:(int)col2 color:(int)color
{
    CGContextRef context = [self getCGContext];
    const NSRect rect = [self rectFromRow:row1 column:col1 toRow:row2 column:col2];
    CGContextSetRGBFillColor(context, RED(color), GREEN(color), BLUE(color), ALPHA(color));
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextFillRect(context, NSRectToCGRect(rect));
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    [self setNeedsDisplayCGLayerInRect:rect];
}

- (void)clearAll
{
    [self releaseCGLayer];
    CGContextRef context = [self getCGContext];
    float r = _defaultBackgroundColor.redComponent;
    float g = _defaultBackgroundColor.greenComponent;
    float b = _defaultBackgroundColor.blueComponent;
    float a = _defaultBackgroundColor.alphaComponent;

    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetRGBFillColor(context, r, g, b, a);
    CGContextFillRect(context, NSRectToCGRect(self.bounds));
    CGContextSetBlendMode(context, kCGBlendModeNormal);

    [self setNeedsDisplayCGLayer:YES];
}

- (void)drawCursorWithParams:(const MMDrawCommandDrawCursor *)p
{
    ASLogNotice(@"   Draw cursor at (%d,%d)", p->row, p->col);

    [self drawInsertionPointAtRow:p->row column:p->col shape:p->shape fraction:p->fraction color:p->color];
}

- (void)drawInsertionPointAtRow:(int)row column:(int)col shape:(int)shape fraction:(int)percent color:(int)color
{
    CGContextRef context = [self getCGContext];
    NSRect rect = [self rectForRow:row column:col numRows:1 numColumns:1];

    CGContextSaveGState(context);

    if (MMInsertionPointHorizontal == shape) {
        rect.size.height = (_cellSize.height * percent + 99) / 100;
    } else if (MMInsertionPointVertical == shape) {
        rect.size.width = (_cellSize.width * percent + 99) / 100;
    } else if (MMInsertionPointVerticalRight == shape) {
        const int frac = (_cellSize.width * percent + 99) / 100;
        rect.origin.x += rect.size.width - frac;
        rect.size.width = frac;
    }

    // Temporarily disable antialiasing since we are only drawing square
    // cursors.  Failing to disable antialiasing can cause the cursor to bleed
    // over into adjacent display cells and it may look ugly.
    CGContextSetShouldAntialias(context, NO);

    if (MMInsertionPointHollow == shape) {
        // When stroking a rect its size is effectively 1 pixel wider/higher
        // than we want so make it smaller to avoid having it bleed over into
        // the adjacent display cell.
        // We also have to shift the rect by half a point otherwise it will be
        // partially drawn outside its bounds on a Retina display.
        rect.size.width -= 1;
        rect.size.height -= 1;
        rect.origin.x += 0.5;
        rect.origin.y += 0.5;

        CGContextSetRGBStrokeColor(context, RED(color), GREEN(color), BLUE(color), ALPHA(color));
        CGContextStrokeRect(context, NSRectToCGRect(rect));
    } else {
        CGContextSetRGBFillColor(context, RED(color), GREEN(color), BLUE(color), ALPHA(color));
        CGContextFillRect(context, NSRectToCGRect(rect));
    }

    [self setNeedsDisplayCGLayerInRect:rect];
    CGContextRestoreGState(context);
}

- (void)drawInvertedRectAtRow:(int)row column:(int)col numRows:(int)nrows numColumns:(int)ncols
{
    // TODO: THIS CODE HAS NOT BEEN TESTED!
    CGContextRef contextRef = [self getCGContext];
    CGContextSaveGState(contextRef);
    CGContextSetBlendMode(contextRef, kCGBlendModeDifference);
    CGContextSetRGBFillColor(contextRef, 1, 1, 1, 1);

    const NSRect rect = [self rectForRow:row column:col numRows:nrows numColumns:ncols];
    CGContextFillRect(contextRef, NSRectToCGRect(rect));

    [self setNeedsDisplayCGLayerInRect:rect];
    CGContextRestoreGState(contextRef);
}

- (void)drawInvertedRectWithParams:(const MMDrawCommandInvertRect *)p
{
    ASLogNotice(@"   Draw inverted rect: row=%d col=%d nrows=%d " "ncols=%d", p->row, p->col, p->numRows, p->numCols);

    [self drawInvertedRectAtRow:p->row column:p->col numRows:p->numRows numColumns:p->numCols];
}

- (void)drawStringWithParams:(const MMDrawCommandDrawString *)p
{
    ASLogNotice(@"   Draw string length=%d row=%d col=%d flags=%#x", p->length, p->row, p->col, p->flags);

    NSString *string = [[NSString alloc] initWithBytesNoCopy:(void *)p->string length:p->length encoding:NSUTF8StringEncoding freeWhenDone:NO];
    [self drawString:string row:p->row column:p->col cells:p->cells flags:p->flags fg:p->fg bg:p->bg sp:p->sp];
}

- (void)drawSignWithParams:(const MMDrawCommandDrawSign *)p
{
    NSString *name = [[NSString alloc] initWithBytesNoCopy:(void *)p->name length:p->length encoding:NSUTF8StringEncoding freeWhenDone:NO];
    NSImage *image = [_helper signImageForName:name];
    NSRect rect = [self rectForRow:p->row column:p->col numRows:p->height numColumns:p->width];
    if (_CGLayerEnabled) {
        CGContextRef context = [self getCGContext];
        CGImageRef imageRef = [image CGImageForProposedRect:&rect context:nil hints:nil];
        CGContextDrawImage(context, rect, imageRef);
    } else {
        [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    }
    self.needsDisplayCGLayerInRect = rect;
}

- (void)moveCursorWithParams:(const MMDrawCommandMoveCursor *)p
{
    // TODO: This is used for Voice Over support in MMTextView,
    // MMCoreTextView currently does not support Voice Over.
    ASLogNotice(@"   Set cursor row=%d col=%d", p->row, p->col);
}

@end // MMCoreTextView (Drawing)

// Any non-zero value will do, but using something recognizable might help us
// debug some day.
static const NSTrackingRectTag kTrackingRectTag = 0xBADFACE;


@implementation MMCoreTextView (ToolTip)

// Override of a public NSView method, replacing the inherited functionality.
// See above for rationale.
- (NSTrackingRectTag)addTrackingRect:(NSRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)assumeInside
{
    //DCHECK(_trackingRectOwner == nil);
    _trackingRectOwner = owner;
    _trackingRectUserData = data;
    return kTrackingRectTag;
}

// Override of (apparently) a private NSView method(!) See above for rationale.
- (NSTrackingRectTag)_addTrackingRect:(NSRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)assumeInside useTrackingNum:(int)tag
{
    //DCHECK(tag == 0 || tag == kTrackingRectTag);
    //DCHECK(_trackingRectOwner == nil);
    _trackingRectOwner = owner;
    _trackingRectUserData = data;
    return kTrackingRectTag;
}

// Override of (apparently) a private NSView method(!) See above for rationale.
- (void)_addTrackingRects:(NSRect *)rects owner:(id)owner userDataList:(void **)userDataList assumeInsideList:(BOOL *)assumeInsideList trackingNums:(NSTrackingRectTag *)trackingNums count:(int)count
{
    //DCHECK(count == 1);
    //DCHECK(trackingNums[0] == 0 || trackingNums[0] == kTrackingRectTag);
    //DCHECK(_trackingRectOwner == nil);
    _trackingRectOwner = owner;
    _trackingRectUserData = userDataList[0];
    trackingNums[0] = kTrackingRectTag;
}

// Override of a public NSView method, replacing the inherited functionality.
// See above for rationale.
- (void)removeTrackingRect:(NSTrackingRectTag)tag
{
    if (tag == 0)
        return;

    if (tag == kTrackingRectTag) {
        _trackingRectOwner = nil;
        return;
    }

    if (tag == _lastToolTipTag) {
        [super removeTrackingRect:tag];
        _lastToolTipTag = 0;
        return;
    }

    // If any other tracking rect is being removed, we don't know how it was
    // created and it's possible there's a leak involved (see Radar 3500217).
    //NOTREACHED();
}

// Override of (apparently) a private NSView method(!)
- (void)_removeTrackingRects:(NSTrackingRectTag *)tags count:(int)count
{
    for (int i = 0; i < count; ++i) {
        const int tag = tags[i];
        if (tag == 0)
            continue;
        //DCHECK(tag == kTrackingRectTag);
        _trackingRectOwner = nil;
    }
}

// Sends a fake NSEventTypeMouseExited event to the view for its current tracking rect.
- (void)_sendToolTipMouseExited
{
    // Nothing matters except window, trackingNumber, and userData.
    NSEvent *fakeEvent = [NSEvent enterExitEventWithType:NSEventTypeMouseExited
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:self.window.windowNumber
                                                 context:NULL
                                             eventNumber:0
                                          trackingNumber:kTrackingRectTag
                                                userData:_trackingRectUserData];
    [_trackingRectOwner mouseExited:fakeEvent];
}

// Sends a fake NSEventTypeMouseEntered event to the view for its current tracking rect.
- (void)_sendToolTipMouseEntered
{
    // Nothing matters except window, trackingNumber, and userData.
    NSEvent *fakeEvent = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:self.window.windowNumber
                                                 context:NULL
                                             eventNumber:0
                                          trackingNumber:kTrackingRectTag
                                                userData:_trackingRectUserData];
    [_trackingRectOwner mouseEntered:fakeEvent];
}

// NSView calls this to get the text when displaying the tooltip.
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data
{
    return _toolTip.copy;
}

@end
