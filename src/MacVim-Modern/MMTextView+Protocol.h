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

/**
 */
@protocol MMTextView <NSObject>

@property (nonatomic) NSSize textContainerInset;
@property (nonatomic, readonly) NSSize cellSize;
@property (nonatomic, readonly) NSSize desiredSize;
@property (nonatomic, readonly) NSSize minSize;
@property (nonatomic, readonly) int maxRows;
@property (nonatomic, readonly) int maxColumns;
@property (nonatomic, readonly) NSColor *defaultForegroundColor;
@property (nonatomic, readonly) NSColor *defaultBackgroundColor;
@property (nonatomic, copy) NSFont *font;
@property (nonatomic, copy) NSFont *fontWide;
@property (nonatomic) int mouseShape;
@property (nonatomic) float linespace;
@property (nonatomic) BOOL antialias;
@property (nonatomic) BOOL ligatures;
@property (nonatomic) BOOL thinStrokes;
@property (nonatomic) BOOL CGLayerEnabled;

- (void)getMaxRows:(int *)rows columns:(int *)cols;
- (void)setMaxRows:(int)rows columns:(int)columns;
- (NSSize)constrainRows:(int *)rows columns:(int *)columns toSize:(NSSize)size;
- (BOOL)convertPoint:(NSPoint)point toRow:(int *)row column:(int *)column;
- (void)setDefaultColorsBackground:(NSColor *)bg foreground:(NSColor *)fg;
- (NSRect)rectForRowsInRange:(NSRange)range;
- (NSRect)rectForColumnsInRange:(NSRange)range;
- (NSRect)rectForRow:(int)row column:(int)column numRows:(int)nr numColumns:(int)nc;
- (void)deleteSign:(NSString *)signName;
- (void)performBatchDrawWithData:(NSData *)data;
- (void)setPreEditRow:(int)row column:(int)col;
- (void)activateIm:(BOOL)enable;
- (void)setImControl:(BOOL)enable;
- (void)checkImState;

@end
