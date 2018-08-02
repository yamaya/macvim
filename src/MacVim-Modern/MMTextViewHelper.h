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

// Need Carbon for TIS...() functions
#import <Carbon/Carbon.h>
#import "MMPoint.h"


#define BLUE(argb)      ((argb & 0xff)/255.0f)
#define GREEN(argb)     (((argb>>8) & 0xff)/255.0f)
#define RED(argb)       (((argb>>16) & 0xff)/255.0f)
#define ALPHA(argb)     (((argb>>24) & 0xff)/255.0f)

@protocol MMTextView;

@interface MMTextViewHelper : NSObject

@property (nonatomic, retain) NSView<MMTextView> *textView;
@property (nonatomic, assign) int mouseShape;
@property (nonatomic, retain) NSDictionary *markedTextAttributes;
@property (nonatomic, retain) NSColor *insertionPointColor;
@property (nonatomic, assign) NSRange inputMethodRange;
@property (nonatomic, assign) NSRange markedRange;
@property (nonatomic, readonly) NSMutableAttributedString *markedText;
@property (nonatomic, assign) MMPoint preeditPoint;
@property (nonatomic, assign) BOOL inputMethodEnabled;
@property (nonatomic, assign) BOOL inputSourceActivated;
@property (nonatomic, readonly) BOOL inlineInputMethodUsed;
@property (nonatomic, readonly) BOOL hasMarkedText;

- (void)setMarkedText:(id)text selectedRange:(NSRange)range;
- (void)keyDown:(NSEvent *)event;
- (void)insertText:(id)string;
- (void)doCommandBySelector:(SEL)selector;
- (void)scrollWheel:(NSEvent *)event;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseMoved:(NSEvent *)event;
- (void)swipeWithEvent:(NSEvent *)event;
- (void)pressureChangeWithEvent:(NSEvent *)event;
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender;
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender;
- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender;
- (void)changeFont:(id)sender;
- (NSImage *)signImageForName:(NSString *)imgName;
- (void)deleteImage:(NSString *)imgName;

// Input Manager
- (void)unmarkText;
- (NSRect)firstRectForCharacterRange:(NSRange)range;
- (void)normalizeInputMethodState;

@end
