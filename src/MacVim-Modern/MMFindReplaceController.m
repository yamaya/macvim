/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMFindReplaceController.h"

@implementation MMFindReplaceController

@synthesize findBox = _findBox, replaceBox = _replaceBox, ignoreCaseButton = _ignoreCaseButton, matchWordButton = _matchWordButton;
@dynamic findString, replaceString, ignoreCase, matchWord;

+ (instancetype)shared
{
    static MMFindReplaceController *singleton = nil;
    if (!singleton) {
        singleton = [[MMFindReplaceController alloc] initWithWindowNibName:@"FindAndReplace"];
        singleton.windowFrameAutosaveName = @"FindAndReplace";
    }
    return singleton;
}

- (void)showWithText:(NSString *)text flags:(int)flags
{
    // Ensure that the window has been loaded by calling this first.
    NSWindow *window = self.window;

    if (text.length != 0) self.findBox.stringValue = text;

    // NOTE: The 'flags' values must match the FRD_ defines in gui.h.
    self.matchWordButton.state = (flags & 0x08 ? NSOnState : NSOffState);
    self.ignoreCaseButton.state = (flags & 0x10 ? NSOffState : NSOnState);

    [window makeKeyAndOrderFront:self];
}

- (NSString *)findString
{
    return self.findBox.stringValue;
}

- (NSString *)replaceString
{
    return self.replaceBox.stringValue;
}

- (BOOL)ignoreCase
{
    return self.ignoreCaseButton.state == NSOnState;
}

- (BOOL)matchWord
{
    return self.matchWordButton.state == NSOnState;
}

@end // MMFindReplaceController
