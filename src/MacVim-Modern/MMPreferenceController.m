/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved            by Bram Moolenaar
 *                              MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMPreferenceController.h"
#import "Miscellaneous.h"

// On Leopard, we want to use the images provided by the OS for some of the
// toolbar images (NSImageNamePreferencesGeneral and friends). We need to jump
// through some hoops to do that in a way that MacVim still _compiles_ on Tiger
// (life would be easier if we'd require Leopard for building). See
// http://developer.apple.com/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/WeakLinking.html
// and http://developer.apple.com/technotes/tn2002/tn2064.html
// for how you'd do it with a Leopard build system, and see
// http://lists.cairographics.org/archives/cairo-bugs/2007-December/001818.html
// for why this doesn't work here.
// Using the system images gives us resolution independence and consistency
// with other apps.

#import <dlfcn.h>

static NSString* nsImageNamePreferencesGeneral;
static NSString* nsImageNamePreferencesAdvanced;

static void loadSymbols()
{
    // use dlfcn() instead of the deprecated NSModule api.
    void *p;
    if ((p = dlsym(RTLD_DEFAULT, "NSImageNamePreferencesGeneral")) != NULL)
        nsImageNamePreferencesGeneral = [*((NSString * __autoreleasing *)p) copy];
    if ((p = dlsym(RTLD_DEFAULT, "NSImageNameAdvanced")) != NULL)
        nsImageNamePreferencesAdvanced = [*((NSString * __autoreleasing *)p) copy];
}


@implementation MMPreferenceController
{
    IBOutlet NSView *_generalPreferences;
    IBOutlet NSView *_advancedPreferences;
    IBOutlet NSPopUpButton *_layoutPopUpButton;
}

- (void)setupToolbar
{
    loadSymbols();

    if (nsImageNamePreferencesGeneral) {
        [self addView:_generalPreferences
                label:@"General"
                image:[NSImage imageNamed:nsImageNamePreferencesGeneral]];
    } else {
        [self addView:_generalPreferences label:@"General"];
    }

    if (nsImageNamePreferencesAdvanced) {
        [self addView:_advancedPreferences
                label:@"Advanced"
                image:[NSImage imageNamed:nsImageNamePreferencesAdvanced]];
    } else {
        [self addView:_advancedPreferences label:@"Advanced"];
    }
}

- (NSString *)currentPaneIdentifier
{
    // We override this to persist the current pane.
    return [NSUserDefaults.standardUserDefaults stringForKey:MMCurrentPreferencePaneKey];
}

- (void)setCurrentPaneIdentifier:(NSString *)identifier
{
    // We override this to persist the current pane.
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:MMCurrentPreferencePaneKey];
}

- (IBAction)openInCurrentWindowSelectionChanged:(id)sender
{
    BOOL openInCurrentWindowSelected = ([[sender selectedCell] tag] != 0);
    BOOL useWindowsLayout = (_layoutPopUpButton.selectedItem.tag == MMLayoutWindows);
    if (openInCurrentWindowSelected && useWindowsLayout)
        [_layoutPopUpButton selectItemWithTag:MMLayoutTabs];
}

@end
