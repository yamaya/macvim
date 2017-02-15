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
#import "MMTextView+Protocol.h"

@class MMTextViewHelper;

@interface MMCoreTextView : NSView <NSTextInput, MMTextView> {
    // These are used in MMCoreTextView+ToolTip.m
    id _trackingRectOwner;              // (not retained)
    void *_trackingRectUserData;
    NSTrackingRectTag _lastToolTipTag;
    NSString* _toolTip;
}

/*
 * MMTextView methods
 */
- (void)setShouldDrawInsertionPoint:(BOOL)on;

/*
 * NSTextView methods
 */
@property (nonatomic, assign) NSSize textContainerInset;
- (void)keyDown:(NSEvent *)event;
- (void)insertText:(id)string;
- (void)doCommandBySelector:(SEL)selector;

@end
