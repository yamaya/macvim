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
#import "MacVim.h"

@class MMWindowController;
@class MMVimController;

@interface MMAppController : NSObject <MMAppProtocol>

@property (nonatomic, retain) NSMenu *mainMenu;
@property (nonatomic, retain) NSMenu *defaultMainMenu;
@property (nonatomic, readonly) NSMenuItem *appMenuItemTemplate;
@property (nonatomic, readonly) MMVimController *keyVimController;

+ (instancetype)shared;

- (void)removeVimController:(id)controller;
- (void)windowControllerWillOpen:(MMWindowController *)windowController;
- (NSArray *)filterOpenFiles:(NSArray *)filenames;
- (BOOL)openFiles:(NSArray *)filenames withArguments:(NSDictionary *)args;

- (IBAction)newWindow:(id)sender;
- (IBAction)newWindowAndActivate:(id)sender;
- (IBAction)fileOpen:(id)sender;
- (IBAction)selectNextWindow:(id)sender;
- (IBAction)selectPreviousWindow:(id)sender;
- (IBAction)orderFrontPreferencePanel:(id)sender;
- (IBAction)openWebsite:(id)sender;
- (IBAction)showVimHelp:(id)sender;
- (IBAction)zoomAll:(id)sender;
- (IBAction)stayInFront:(id)sender;
- (IBAction)stayInBack:(id)sender;
- (IBAction)stayLevelNormal:(id)sender;

@end
