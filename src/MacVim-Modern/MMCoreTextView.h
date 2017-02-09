/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import <Cocoa/Cocoa.h>

@class MMTextViewHelper;

@interface MMCoreTextView : NSView <NSTextInput> {
    // These are used in MMCoreTextView+ToolTip.m
    id _trackingRectOwner;              // (not retained)
    void *_trackingRectUserData;
    NSTrackingRectTag _lastToolTipTag;
    NSString* _toolTip;
}

/*
 * MMTextStorage methods
 */
@property (nonatomic, readonly) int maxRows;
@property (nonatomic, readonly) int maxColumns;
@property (nonatomic, readonly) NSColor *defaultForegroundColor;
@property (nonatomic, readonly) NSColor *defaultBackgroundColor;
@property (nonatomic, retain) NSFont *font;
@property (nonatomic, retain) NSFont *fontWide;
@property (nonatomic, readonly) NSSize cellSize;
@property (nonatomic) float linespace;
- (void)setMaxRows:(int)rows columns:(int)cols;
- (void)getMaxRows:(int *)rows columns:(int *)cols;
- (void)setDefaultColorsBackground:(NSColor *)bg foreground:(NSColor *)fg;
- (NSRect)rectForRowsInRange:(NSRange)range;
- (NSRect)rectForColumnsInRange:(NSRange)range;
- (void)setWideFont:(NSFont *)font; // FIXME: あとで消す

/*
 * MMTextView methods
 */
@property (nonatomic, assign) BOOL antialias;
@property (nonatomic, assign) BOOL ligatures;
@property (nonatomic, assign) BOOL thinStrokes;
@property (nonatomic, assign) BOOL CGLayerEnabled;
- (void)deleteSign:(NSString *)signName;
- (void)setShouldDrawInsertionPoint:(BOOL)on;
- (void)setPreEditRow:(int)row column:(int)col;
- (void)setMouseShape:(int)shape;
- (void)setImControl:(BOOL)enable;
- (void)activateIm:(BOOL)enable;
- (void)checkImState;
- (BOOL)convertPoint:(NSPoint)point toRow:(int *)row column:(int *)column;
- (NSRect)rectForRow:(int)row column:(int)column numRows:(int)nr numColumns:(int)nc;

/*
 * NSTextView methods
 */
@property (nonatomic, assign) NSSize textContainerInset;
- (void)keyDown:(NSEvent *)event;
- (void)insertText:(id)string;
- (void)doCommandBySelector:(SEL)selector;

/*
 * MMCoreTextView methods
 */
@property (nonatomic, readonly) NSSize desiredSize;
@property (nonatomic, readonly) NSSize minSize;
- (void)performBatchDrawWithData:(NSData *)data;
- (NSSize)constrainRows:(int *)rows columns:(int *)cols toSize:(NSSize)size;

@end

/*
 * This category is defined in MMCoreTextView+ToolTip.m
 */
@interface MMCoreTextView (ToolTip)
- (void)setToolTipAtMousePoint:(NSString *)string;
@end
