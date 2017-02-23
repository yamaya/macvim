/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved            by Bram Moolenaar
 *                              MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import <Cocoa/Cocoa.h>

@class MMVimView;

@interface MMFullScreenWindow : NSWindow

- (instancetype)initWithWindow:(NSWindow *)t view:(MMVimView *)v backgroundColor:(NSColor *)back;
- (void)setOptions:(int)opt;
- (void)enterFullScreen;
- (void)leaveFullScreen;
- (void)centerView;

- (BOOL)canBecomeKeyWindow;
- (BOOL)canBecomeMainWindow;

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification;
@end
