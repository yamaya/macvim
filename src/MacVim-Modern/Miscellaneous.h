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

// TODO: Remove this when the inline IM code has been tested
#define INCLUDE_OLD_IM_CODE


// NSUserDefaults keys
extern NSString *const MMTabMinWidthKey;
extern NSString *const MMTabMaxWidthKey;
extern NSString *const MMTabOptimumWidthKey;
extern NSString *const MMShowAddTabButtonKey;
extern NSString *const MMTextInsetLeftKey;
extern NSString *const MMTextInsetRightKey;
extern NSString *const MMTextInsetTopKey;
extern NSString *const MMTextInsetBottomKey;
extern NSString *const MMTypesetterKey;
extern NSString *const MMCellWidthMultiplierKey;
extern NSString *const MMBaselineOffsetKey;
extern NSString *const MMTranslateCtrlClickKey;
extern NSString *const MMTopLeftPointKey;
extern NSString *const MMOpenInCurrentWindowKey;
extern NSString *const MMNoFontSubstitutionKey;
extern NSString *const MMNoTitleBarWindowKey;
extern NSString *const MMLoginShellKey;
extern NSString *const MMUntitledWindowKey;
extern NSString *const MMZoomBothKey;
extern NSString *const MMCurrentPreferencePaneKey;
extern NSString *const MMLoginShellCommandKey;
extern NSString *const MMLoginShellArgumentKey;
extern NSString *const MMDialogsTrackPwdKey;
extern NSString *const MMOpenLayoutKey;
extern NSString *const MMVerticalSplitKey;
extern NSString *const MMPreloadCacheSizeKey;
extern NSString *const MMLastWindowClosedBehaviorKey;
#ifdef INCLUDE_OLD_IM_CODE
extern NSString *const MMUseInlineImKey;
#endif // INCLUDE_OLD_IM_CODE
extern NSString *const MMSuppressTerminationAlertKey;
extern NSString *const MMNativeFullScreenKey;
extern NSString *const MMUseMouseTimeKey;
extern NSString *const MMFullScreenFadeTimeKey;
extern NSString *const MMUseCGLayerAlwaysKey;


// Enum for MMUntitledWindowKey
enum {
    MMUntitledWindowNever = 0,
    MMUntitledWindowOnOpen = 1,
    MMUntitledWindowOnReopen = 2,
    MMUntitledWindowAlways = 3
};

// Enum for MMOpenLayoutKey (first 4 must match WIN_* defines in main.c)
enum {
    MMLayoutArglist = 0,
    MMLayoutHorizontalSplit = 1,
    MMLayoutVerticalSplit = 2,
    MMLayoutTabs = 3,
    MMLayoutWindows = 4,
};

// Enum for MMLastWindowClosedBehaviorKey
enum {
    MMDoNothingWhenLastWindowClosed = 0,
    MMHideWhenLastWindowClosed = 1,
    MMTerminateWhenLastWindowClosed = 2,
};



enum {
    // These values are chosen so that the min text view size is not too small
    // with the default font (they only affect resizing with the mouse, you can
    // still use e.g. ":set lines=2" to go below these values).
    MMMinRows = 4,
    MMMinColumns = 30
};


/**
 */
@interface NSIndexSet (MMExtras)
+ (instancetype)indexSetWithVimList:(NSString *)list;
@end

/**
 */
@interface NSDocumentController (MMExtras)
- (void)noteNewRecentFilePath:(NSString *)path;
- (void)noteNewRecentFilePaths:(NSArray *)paths;
@end

/**
 */
@interface NSSavePanel (MMExtras)
- (void)hiddenFilesButtonToggled:(id)sender;
@end

/**
 */
@interface NSMenu (MMExtras)
- (NSInteger)indexOfItemWithAction:(SEL)action;
- (NSMenuItem *)itemWithAction:(SEL)action;
- (NSMenu *)findMenuContainingItemWithAction:(SEL)action;
- (NSMenu *)findWindowsMenu;
- (NSMenu *)findApplicationMenu;
- (NSMenu *)findServicesMenu;
- (NSMenu *)findFileMenu;
@end

/**
 */
@interface NSToolbar (MMExtras)
- (NSUInteger)indexOfItemWithItemIdentifier:(NSString *)identifier;
- (NSToolbarItem *)itemAtIndex:(NSUInteger)idx;
- (NSToolbarItem *)itemWithItemIdentifier:(NSString *)identifier;
@end

/**
 */
@interface NSTabView (MMExtras)
- (void)removeAllTabViewItems;
@end

/**
 */
@interface NSNumber (MMExtras)
// HACK to allow font size to be changed via menu (bound to Cmd+/Cmd-)
- (NSInteger)tag;
@end


// Create a view with a "show hidden files" button to be used as accessory for
// open/save panels.  This function assumes ownership of the view so do not
// release it.
extern NSView *showHiddenFilesView();


// Convert filenames (which are in a variant of decomposed form, NFD, on HFS+)
// to normalization form C (NFC).  (This is necessary because Vim does not
// automatically compose NFD.)  For more information see:
//     http://developer.apple.com/technotes/tn/tn1150.html
//     http://developer.apple.com/technotes/tn/tn1150table.html
//     http://developer.apple.com/qa/qa2001/qa1235.html
//     http://www.unicode.org/reports/tr15/
extern NSString *normalizeFilename(NSString *filename);
extern NSArray *normalizeFilenames(NSArray *filenames);


extern BOOL shouldUseYosemiteTabBarStyle();
