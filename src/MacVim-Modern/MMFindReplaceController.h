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
@interface MMFindReplaceController : NSWindowController

@property (nonatomic, retain) IBOutlet NSTextField  *findBox;
@property (nonatomic, retain) IBOutlet NSTextField  *replaceBox;
@property (nonatomic, retain) IBOutlet NSButton *ignoreCaseButton;
@property (nonatomic, retain) IBOutlet NSButton *matchWordButton;
@property (nonatomic, readonly) NSString    *findString;
@property (nonatomic, readonly) NSString    *replaceString;
@property (nonatomic, readonly) BOOL    ignoreCase;
@property (nonatomic, readonly) BOOL    matchWord;

+ (instancetype)shared;

- (void)showWithText:(NSString *)text flags:(int)flags;

@end
