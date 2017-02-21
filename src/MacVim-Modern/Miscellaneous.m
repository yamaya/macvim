/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MacVim.h"
#import "Miscellaneous.h"

// NSUserDefaults keys
NSString *const MMTabMinWidthKey              = @"MMTabMinWidth";
NSString *const MMTabMaxWidthKey              = @"MMTabMaxWidth";
NSString *const MMTabOptimumWidthKey          = @"MMTabOptimumWidth";
NSString *const MMShowAddTabButtonKey         = @"MMShowAddTabButton";
NSString *const MMTextInsetLeftKey            = @"MMTextInsetLeft";
NSString *const MMTextInsetRightKey           = @"MMTextInsetRight";
NSString *const MMTextInsetTopKey             = @"MMTextInsetTop";
NSString *const MMTextInsetBottomKey          = @"MMTextInsetBottom";
NSString *const MMTypesetterKey               = @"MMTypesetter";
NSString *const MMCellWidthMultiplierKey      = @"MMCellWidthMultiplier";
NSString *const MMBaselineOffsetKey           = @"MMBaselineOffset";
NSString *const MMTranslateCtrlClickKey       = @"MMTranslateCtrlClick";
NSString *const MMTopLeftPointKey             = @"MMTopLeftPoint";
NSString *const MMOpenInCurrentWindowKey      = @"MMOpenInCurrentWindow";
NSString *const MMNoFontSubstitutionKey       = @"MMNoFontSubstitution";
NSString *const MMNoTitleBarWindowKey         = @"MMNoTitleBarWindow";
NSString *const MMLoginShellKey               = @"MMLoginShell";
NSString *const MMUntitledWindowKey           = @"MMUntitledWindow";
NSString *const MMZoomBothKey                 = @"MMZoomBoth";
NSString *const MMCurrentPreferencePaneKey    = @"MMCurrentPreferencePane";
NSString *const MMLoginShellCommandKey        = @"MMLoginShellCommand";
NSString *const MMLoginShellArgumentKey       = @"MMLoginShellArgument";
NSString *const MMDialogsTrackPwdKey          = @"MMDialogsTrackPwd";
NSString *const MMOpenLayoutKey               = @"MMOpenLayout";
NSString *const MMVerticalSplitKey            = @"MMVerticalSplit";
NSString *const MMPreloadCacheSizeKey         = @"MMPreloadCacheSize";
NSString *const MMLastWindowClosedBehaviorKey = @"MMLastWindowClosedBehavior";
#ifdef INCLUDE_OLD_IM_CODE
NSString *const MMUseInlineImKey              = @"MMUseInlineIm";
#endif // INCLUDE_OLD_IM_CODE
NSString *const MMSuppressTerminationAlertKey = @"MMSuppressTerminationAlert";
NSString *const MMNativeFullScreenKey         = @"MMNativeFullScreen";
NSString *const MMUseMouseTimeKey             = @"MMUseMouseTime";
NSString *const MMFullScreenFadeTimeKey       = @"MMFullScreenFadeTime";
NSString *const MMUseCGLayerAlwaysKey         = @"MMUseCGLayerAlways";

/**
 */
@implementation NSIndexSet (MMExtras)

+ (instancetype)indexSetWithVimList:(NSString *)list
{
    NSMutableIndexSet *set = NSMutableIndexSet.new;
    NSArray *components = [list componentsSeparatedByString:@"\n"];
    for (NSString *component in components) {
        if (component.intValue > 0)
            [set addIndex:[components indexOfObject:component]];
    }
    return set.copy;
}

@end // NSIndexSet (MMExtras)

/**
 */
@implementation NSDocumentController (MMExtras)

- (void)noteNewRecentFilePath:(NSString *)path
{
    NSURL *url = [NSURL fileURLWithPath:path];
    if (url) [self noteNewRecentDocumentURL:url];
}

- (void)noteNewRecentFilePaths:(NSArray *)paths
{
    for (NSString *path in paths) {
        [self noteNewRecentFilePath:path];
    }
}

@end // NSDocumentController (MMExtras)

/**
 */
@implementation NSSavePanel (MMExtras)

- (void)hiddenFilesButtonToggled:(id)sender
{
    self.showsHiddenFiles = [sender intValue];
}

@end // NSSavePanel (MMExtras)

/**
 */
@implementation NSMenu (MMExtras)

- (int)indexOfItemWithAction:(SEL)action
{
    for (NSUInteger n = self.numberOfItems, i = 0; i < n; ++i) {
        NSMenuItem *item = [self itemAtIndex:i];
        if (item.action == action)
            return i;
    }

    return -1;
}

- (NSMenuItem *)itemWithAction:(SEL)action
{
    int idx = [self indexOfItemWithAction:action];
    return idx >= 0 ? [self itemAtIndex:idx] : nil;
}

- (NSMenu *)findMenuContainingItemWithAction:(SEL)action
{
    // NOTE: We only look for the action in the submenus of 'self'
    int i, count = [self numberOfItems];
    for (i = 0; i < count; ++i) {
        NSMenu *menu = [[self itemAtIndex:i] submenu];
        NSMenuItem *item = [menu itemWithAction:action];
        if (item) return menu;
    }

    return nil;
}

- (NSMenu *)findWindowsMenu
{
    return [self findMenuContainingItemWithAction:@selector(performMiniaturize:)];
}

- (NSMenu *)findApplicationMenu
{
    // TODO: Just return [self itemAtIndex:0]?
    return [self findMenuContainingItemWithAction:@selector(terminate:)];
}

- (NSMenu *)findServicesMenu
{
    // NOTE!  Our heuristic for finding the "Services" menu is to look for the
    // second item before the "Hide MacVim" menu item on the "MacVim" menu.
    // (The item before "Hide MacVim" should be a separator, but this is not
    // important as long as the item before that is the "Services" menu.)

    NSMenu *appMenu = self.findApplicationMenu;
    if (!appMenu) return nil;

    const int index = [appMenu indexOfItemWithAction:@selector(hide:)];
    if (index - 2 < 0) return nil;  // index == -1, if selector not found

    return [[appMenu itemAtIndex:index - 2] submenu];
}

- (NSMenu *)findFileMenu
{
    return [self findMenuContainingItemWithAction:@selector(performClose:)];
}

@end // NSMenu (MMExtras)

/**
 */
@implementation NSToolbar (MMExtras)

- (NSUInteger)indexOfItemWithItemIdentifier:(NSString *)identifier
{
    for (NSToolbarItem *item in self.items) {
        if ([item.itemIdentifier isEqualToString:identifier]) {
            return [self.items indexOfObject:item];
        }
    }
    return NSNotFound;
}

- (NSToolbarItem *)itemAtIndex:(NSUInteger)index
{
    NSArray *items = self.items;
    if (index >= items.count) return nil;
    return items[index];
}

- (NSToolbarItem *)itemWithItemIdentifier:(NSString *)identifier
{
    const NSUInteger i = [self indexOfItemWithItemIdentifier:identifier];
    return i != NSNotFound ? [self itemAtIndex:i] : nil;
}

@end // NSToolbar (MMExtras)

/**
 */
@implementation NSTabView (MMExtras)

- (void)removeAllTabViewItems
{
    NSArray *existingItems = [self tabViewItems];
    NSEnumerator *e = [existingItems objectEnumerator];
    NSTabViewItem *item;
    while ((item = [e nextObject])) {
        [self removeTabViewItem:item];
    }
}

@end // NSTabView (MMExtras)

/**
 */
@implementation NSNumber (MMExtras)

// HACK to allow font size to be changed via menu (bound to Cmd+/Cmd-)
- (NSInteger)tag
{
    return self.intValue;
}

@end // NSNumber (MMExtras)

NSView *
showHiddenFilesView()
{
    // Return a new button object for each NSOpenPanel -- several of them
    // could be displayed at once.
    // If the accessory view should get more complex, it should probably be
    // loaded from a nib file.
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 140, 18)];
    button.title = NSLocalizedString(@"Show Hidden Files", @"Show Hidden Files Checkbox");
    button.buttonType = NSSwitchButton;

    button.target = nil;
    button.action = @selector(hiddenFilesButtonToggled:);

    // Use the regular control size (checkbox is a bit smaller without this)
    const NSControlSize buttonSize = NSControlSizeRegular;
    const float fontSize = [NSFont systemFontSizeForControlSize:buttonSize];
    NSCell *cell = button.cell;
    cell.font = [NSFont fontWithName:cell.font.fontName size:fontSize];
    cell.controlSize = buttonSize;
    [button sizeToFit];

    return button;
}

NSString *
normalizeFilename(NSString *filename)
{
    return filename.precomposedStringWithCanonicalMapping;
}

NSArray *
normalizeFilenames(NSArray *filenames)
{
    NSMutableArray *names = NSMutableArray.new;
    if (!filenames) return names.copy;

    for (NSString *filename in filenames) {
        [names addObject:normalizeFilename(filename)];
    }

    return names.copy;
}

BOOL
shouldUseYosemiteTabBarStyle()
{ 
    return floor(NSAppKitVersionNumber) >= NSAppKitVersionNumber10_10;
}
