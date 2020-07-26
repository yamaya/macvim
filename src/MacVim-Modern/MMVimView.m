/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */
/*
 * MMVimView
 *
 * A view class with a tabline, scrollbars, and a text view.  The tabline may
 * appear at the top of the view in which case it fills up the view from left
 * to right edge.  Any number of scrollbars may appear adjacent to all other
 * edges of the view (there may be more than one scrollbar per edge and
 * scrollbars may also be placed on the left edge of the view).  The rest of
 * the view is filled by the text view.
 */

#import "Miscellaneous.h"
#import "MMCoreTextView.h"
#import "MMVimController.h"
#import "MMVimView.h"
#import "MMWindowController.h"
#import "MMScroller.h"
#import <PSMTabBarControl/PSMTabBarControl.h>

/**
 */
@interface MMVimView ()
- (BOOL)bottomScrollbarVisible;
- (BOOL)leftScrollbarVisible;
- (BOOL)rightScrollbarVisible;
- (void)placeScrollbars;
- (NSUInteger)representedIndexOfTabViewItem:(NSTabViewItem *)tvi;
- (MMScroller *)scrollbarForIdentifier:(int32_t)ident index:(unsigned *)idx;
- (NSSize)vimViewSizeForTextViewSize:(NSSize)textViewSize;
- (NSRect)textViewRectForVimViewSize:(NSSize)contentSize;
- (void)frameSizeMayHaveChanged;
@end

/**
 */
@implementation MMVimView
{
    MMVimController     *_vimController;
    NSMutableArray      *_scrollbars;
    NSTabView           *_tabView;
    BOOL                _vimTaskSelectedTab;
}
@synthesize textView = _textView, tabBarControl = _tabBarControl;
@dynamic desiredSize, minSize;

- (instancetype)initWithFrame:(NSRect)frame vimController:(MMVimController *)controller
{
    if (!(self = [super initWithFrame:frame])) return nil;
    
    _vimController = controller;
    _scrollbars = NSMutableArray.new;

    // Only the tabline is autoresized, all other subview placement is done in
    // frameSizeMayHaveChanged.
    self.autoresizesSubviews = YES;

    _textView = [[MMCoreTextView alloc] initWithFrame:frame];

    // Allow control of text view inset via MMTextInset* user defaults.
    _textView.textContainerInset = (NSSize){
        [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetLeftKey],
        [NSUserDefaults.standardUserDefaults integerForKey:MMTextInsetTopKey],
    };

    _textView.autoresizingMask = NSViewNotSizable;
    [self addSubview:_textView];
    
    // Create the tab view (which is never visible, but the tab bar control
    // needs it to function).
    _tabView = [[NSTabView alloc] initWithFrame:NSZeroRect];

    // Create the tab bar control (which is responsible for actually
    // drawing the tabline and tabs).
    _tabBarControl = [[PSMTabBarControl alloc] initWithFrame:(NSRect){
        {0, frame.size.height - kPSMTabBarControlHeight},
        {frame.size.width, kPSMTabBarControlHeight}
    }];

    _tabView.delegate = _tabBarControl;

    _tabBarControl.tabView = _tabView;
    _tabBarControl.delegate = self;
    _tabBarControl.hidden = YES;

    if (shouldUseYosemiteTabBarStyle()) {
        const CGFloat screenWidth = NSScreen.mainScreen.frame.size.width;
        _tabBarControl.styleNamed = @"Yosemite";
        _tabBarControl.cellMinWidth = [NSUserDefaults.standardUserDefaults integerForKey:MMTabMinWidthKey];
        _tabBarControl.cellMaxWidth = [NSUserDefaults.standardUserDefaults integerForKey:MMTabMaxWidthKey] ?: screenWidth;
        _tabBarControl.cellOptimumWidth = [NSUserDefaults.standardUserDefaults integerForKey:MMTabOptimumWidthKey] ?: screenWidth;
    } else {
        _tabBarControl.cellMinWidth = [NSUserDefaults.standardUserDefaults integerForKey:MMTabMinWidthKey];
        _tabBarControl.cellMaxWidth = [NSUserDefaults.standardUserDefaults integerForKey:MMTabMaxWidthKey];
        _tabBarControl.cellOptimumWidth = [NSUserDefaults.standardUserDefaults integerForKey:MMTabOptimumWidthKey];
    }

    _tabBarControl.showAddTabButton = [NSUserDefaults.standardUserDefaults boolForKey:MMShowAddTabButtonKey];
    [(id)[_tabBarControl addTabButton] setTarget:self];
    [(id)[_tabBarControl addTabButton] setAction:@selector(addNewTab:)];
    _tabBarControl.allowsDragBetweenWindows = NO;
    [_tabBarControl registerForDraggedTypes:@[NSFilenamesPboardType]];
    _tabBarControl.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    
    //[_tabBarControl setPartnerView:textView];
    
    // tab bar resizing only works if awakeFromNib is called (that's where
    // the NSViewFrameDidChangeNotification callback is installed). Sounds like
    // a PSMTabBarControl bug, let's live with it for now.
    [_tabBarControl awakeFromNib];

    [self addSubview:_tabBarControl];

    return self;
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)drawRect:(NSRect)rect
{
    // On Leopard, we want to have a textured window background for nice
    // looking tabs. However, the textured window background looks really
    // weird behind the window resize throbber, so emulate the look of an
    // NSScrollView in the bottom right corner.
    if (!self.window.showsResizeIndicator || !(self.window.styleMask & NSWindowStyleMaskTexturedBackground))
        return;

#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7)
    const int sw = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
#else
    const int sw = NSScroller.scrollerWidth;
#endif

    // add .5 to the pixel locations to put the lines on a pixel boundary.
    // the top and right edges of the rect will be outside of the bounds rect
    // and clipped away.
    //NSBezierPath* path = [NSBezierPath bezierPath];
    NSBezierPath* path = [NSBezierPath bezierPathWithRect:(NSRect){
        {self.bounds.size.width - sw + .5, -.5}, {sw, sw}
    }];

    // On Tiger, we have color #E8E8E8 behind the resize throbber
    // (which is windowBackgroundColor on untextured windows or controlColor in
    // general). Terminal.app on Leopard has #FFFFFF background and #D9D9D9 as
    // stroke. The colors below are #FFFFFF and #D4D4D4, which is close enough
    // for me.
    [NSColor.controlBackgroundColor set];
    [path fill];

    [NSColor.secondarySelectedControlColor set];
    [path stroke];

    if (self.leftScrollbarVisible) {
        // If the left scrollbar is visible there is an empty square under it.
        // Fill it in just like on the right hand corner.  The half pixel
        // offset ensures the outline goes on the top and right side of the
        // square; the left and bottom parts of the outline are clipped.
        path = [NSBezierPath bezierPathWithRect:NSMakeRect(-.5, -.5, sw, sw)];
        [NSColor.controlBackgroundColor set];
        [path fill];
        [NSColor.secondarySelectedControlColor set];
        [path stroke];
    }
}

- (void)cleanup
{
    _vimController = nil;
    
    // NOTE! There is a bug in PSMTabBarControl in that it retains the delegate
    // so reset the delegate here, otherwise the delegate may never get
    // released.
    _tabView.delegate = nil;
    _tabBarControl.delegate = nil;
    _tabBarControl.tabView = nil;
    self.window.delegate = nil;

    // NOTE! There is another bug in PSMTabBarControl where the control is not
    // removed as an observer, so remove it here (failing to remove an observer
    // may lead to very strange bugs).
    [NSNotificationCenter.defaultCenter removeObserver:_tabBarControl];

    [_tabBarControl removeFromSuperviewWithoutNeedingDisplay];
    [_textView removeFromSuperviewWithoutNeedingDisplay];

    for (MMScroller *scroller in _scrollbars) {
        [scroller removeFromSuperviewWithoutNeedingDisplay];
    }

    [_tabView removeAllTabViewItems];
}

- (NSSize)desiredSize
{
    return [self vimViewSizeForTextViewSize:_textView.desiredSize];
}

- (NSSize)minSize
{
    return [self vimViewSizeForTextViewSize:_textView.minSize];
}

- (NSSize)constrainRows:(int *)outRows columns:(int *)outCols toSize:(NSSize)size
{
    size = [self textViewRectForVimViewSize:size].size;
    size = [_textView constrainRows:outRows columns:outCols toSize:size];
    return [self vimViewSizeForTextViewSize:size];
}

- (void)setDesiredRows:(int)rows columns:(int)cols
{
    _textView.maxSize = (MMPoint){rows, cols};
}

- (IBAction)addNewTab:(id)sender
{
    [_vimController sendMessage:AddNewTabMsgID data:nil];
}

- (void)updateTabsWithData:(NSData *)data
{
    const void *p = data.bytes;
    const void *end = p + data.length;
    int tabIndex = 0;

    // HACK!  Current tab is first in the message.  This way it is not
    // necessary to guess which tab should be the selected one (this can be
    // problematic for instance when new tabs are created).
    int curtabIdx = *((int *)p);  p += sizeof(int);

    NSArray *tabViewItems = _tabBarControl.representedTabViewItems;

    while (p < end) {
        NSTabViewItem *tvi = nil;

        const int infoCount = *((int *)p); p += sizeof(int);
        for (int i = 0; i < infoCount; ++i) {
            const int length = *((int *)p);  p += sizeof(int);
            if (length <= 0)
                continue;

            NSString *val = [[NSString alloc] initWithBytes:p length:length encoding:NSUTF8StringEncoding];
            p += length;

            switch (i) {
                case MMTabLabel:
                    // Set the label of the tab, adding a new tab when needed.
                    tvi = _tabView.numberOfTabViewItems <= tabIndex ? [self addNewTabViewItem] : tabViewItems[tabIndex];
                    tvi.label = val;
                    ++tabIndex;
                    break;
                case MMTabToolTip:
                    if (tvi) [_tabBarControl setToolTip:val forTabViewItem:tvi];
                    break;
                default:
                    ASLogWarn(@"Unknown tab info for index: %d", i);
                    break;
            }
        }
    }

    // Remove unused tabs from the NSTabView.  Note that when a tab is closed
    // the NSTabView will automatically select another tab, but we want Vim to
    // take care of which tab to select so set the vimTaskSelectedTab flag to
    // prevent the tab selection message to be passed on to the VimTask.
    _vimTaskSelectedTab = YES;
    for (int i = _tabView.numberOfTabViewItems - 1; i >= tabIndex; --i) {
        [_tabView removeTabViewItem:tabViewItems[i]];
    }
    _vimTaskSelectedTab = NO;

    [self selectTabWithIndex:curtabIdx];
}

- (void)selectTabWithIndex:(int)index
{
    NSArray *tabViewItems = _tabBarControl.representedTabViewItems;
    if (index < 0 || index >= tabViewItems.count) {
        ASLogWarn(@"No tab with index %d exists.", index);
        return;
    }

    // Do not try to select a tab if already selected.
    NSTabViewItem *item = tabViewItems[index];
    if (item != _tabView.selectedTabViewItem) {
        _vimTaskSelectedTab = YES;
        [_tabView selectTabViewItem:item];
        _vimTaskSelectedTab = NO;

        // We might need to change the scrollbars that are visible.
        [self placeScrollbars];
    }
}

- (NSTabViewItem *)addNewTabViewItem
{
    // NOTE!  A newly created tab is not by selected by default; Vim decides
    // which tab should be selected at all times.  However, the AppKit will
    // automatically select the first tab added to a tab view.

    // The documentation claims initWithIdentifier can be given a nil identifier, but the API itself
    // is decorated such that doing so produces a warning, so the tab count is used as identifier.
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@(_tabView.numberOfTabViewItems)];

    // NOTE: If this is the first tab it will be automatically selected.
    _vimTaskSelectedTab = YES;
    [_tabView addTabViewItem:item];
    _vimTaskSelectedTab = NO;

    return item;
}

- (void)createScrollbarWithIdentifier:(int32_t)identifier type:(MMScrollerType)type
{
    MMScroller *scroller = [[MMScroller alloc] initWithIdentifier:identifier type:type];
    scroller.target = self;
    scroller.action = @selector(scroll:);

    [self addSubview:scroller];
    [_scrollbars addObject:scroller];
}

- (BOOL)destroyScrollbarWithIdentifier:(int32_t)identifier
{
    unsigned index = 0;
    MMScroller *scroller = [self scrollbarForIdentifier:identifier index:&index];
    if (!scroller) return NO;

    [scroller removeFromSuperview];
    [_scrollbars removeObjectAtIndex:index];

    // If a visible scroller was removed then the vim view must resize.  This
    // is handled by the window controller (the vim view never resizes itself).
    return !scroller.isHidden;
}

- (BOOL)showScrollbarWithIdentifier:(int32_t)identifier state:(BOOL)visible
{
    MMScroller *scroller = [self scrollbarForIdentifier:identifier index:nil];
    if (!scroller) return NO;

    const BOOL wasVisible = !scroller.isHidden;
    scroller.hidden = !visible;

    // If a scroller was hidden or shown then the vim view must resize.  This
    // is handled by the window controller (the vim view never resizes itself).
    return wasVisible != visible;
}

- (void)setScrollbarThumbValue:(float)value proportion:(float)proportion identifier:(int32_t)identifier
{
    MMScroller *scroller = [self scrollbarForIdentifier:identifier index:NULL];
    scroller.doubleValue = value;
    scroller.knobProportion = proportion;
    scroller.enabled = (proportion != 1);
}

- (void)scroll:(MMScroller *)scroller
{
    const int32_t identifier = scroller.identifier;
    const int hitPart = scroller.hitPart;
    const float value = scroller.floatValue;

    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&identifier length:sizeof(identifier)];
    [data appendBytes:&hitPart length:sizeof(hitPart)];
    [data appendBytes:&value length:sizeof(value)];

    [_vimController sendMessage:ScrollbarEventMsgID data:data];
}

- (void)setScrollbarPosition:(int)position length:(int)length identifier:(int32_t)identifier
{
    MMScroller *scroller = [self scrollbarForIdentifier:identifier index:nil];
    const NSRange range = NSMakeRange(position, length);
    if (!NSEqualRanges(range, scroller.range)) {
        scroller.range = range;
        // TODO!  Should only do this once per update.

        // This could be sent because a text window was created or closed, so
        // we might need to update which scrollbars are visible.
        [self placeScrollbars];
    }
}

- (void)setDefaultColorsBackground:(NSColor *)back foreground:(NSColor *)fore
{
    [_textView setDefaultColorsBackground:back foreground:fore];
}

// -- PSMTabBarControl delegate ----------------------------------------------

- (BOOL)tabView:(NSTabView *)theTabView shouldSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
    // NOTE: It would be reasonable to think that 'shouldSelect...' implies
    // that this message only gets sent when the user clicks the tab.
    // Unfortunately it is not so, which is why we need the
    // 'vimTaskSelectedTab' flag.
    //
    // HACK!  The selection message should not be propagated to Vim if Vim
    // selected the tab (e.g. as opposed the user clicking the tab).  The
    // delegate method has no way of knowing who initiated the selection so a
    // flag is set when Vim initiated the selection.
    if (!_vimTaskSelectedTab) {
        // Propagate the selection message to Vim.
        const NSUInteger index = [self representedIndexOfTabViewItem:tabViewItem];
        if (NSNotFound != index) {
            const int i = (int)index;   // HACK! Never more than MAXINT tabs?!
            NSData *data = [NSData dataWithBytes:&i length:sizeof(i)];
            [_vimController sendMessage:SelectTabMsgID data:data];
        }
    }

    // Unless Vim selected the tab, return NO, and let Vim decide if the tab
    // should get selected or not.
    return _vimTaskSelectedTab;
}

- (BOOL)tabView:(NSTabView *)theTabView shouldCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
    // HACK!  This method is only called when the user clicks the close button
    // on the tab.  Instead of letting the tab bar close the tab, we return NO
    // and pass a message on to Vim to let it handle the closing.
    NSUInteger index = [self representedIndexOfTabViewItem:tabViewItem];
    const int i = (int)index;   // HACK! Never more than MAXINT tabs?!
    NSData *data = [NSData dataWithBytes:&i length:sizeof(i)];
    [_vimController sendMessage:CloseTabMsgID data:data];

    return NO;
}

- (void)tabView:(NSTabView *)theTabView didDragTabViewItem:(NSTabViewItem *)tabViewItem toIndex:(int)index
{
    NSMutableData *data = NSMutableData.new;
    [data appendBytes:&index length:sizeof(int)];
    [_vimController sendMessage:DraggedTabMsgID data:data];
}

- (NSDragOperation)tabBarControl:(PSMTabBarControl *)theTabBarControl draggingEntered:(id <NSDraggingInfo>)sender forTabAtIndex:(NSUInteger)tabIndex
{
    NSPasteboard *pb = sender.draggingPasteboard;
    return [pb.types containsObject:NSFilenamesPboardType] ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)tabBarControl:(PSMTabBarControl *)theTabBarControl performDragOperation:(id <NSDraggingInfo>)sender forTabAtIndex:(NSUInteger)tabIndex
{
    NSPasteboard *pb = sender.draggingPasteboard;
    if ([pb.types containsObject:NSFilenamesPboardType]) {
        NSArray *filenames = [pb propertyListForType:NSFilenamesPboardType];
        if (filenames.count == 0) {
            return NO;
        }
        if (tabIndex != NSNotFound) {
            // If dropping on a specific tab, only open one file
            [_vimController file:filenames.firstObject draggedToTabAtIndex:tabIndex];
        } else {
            // Files were dropped on empty part of tab bar; open them all
            [_vimController filesDraggedToTabBar:filenames];
        }
        return YES;
    }
    return NO;
}

// -- NSView customization ---------------------------------------------------

- (void)viewWillStartLiveResize
{
    [self.window.windowController liveResizeWillStart];
    [super viewWillStartLiveResize];
}

- (void)viewDidEndLiveResize
{
    [self.window.windowController liveResizeDidEnd];
    [super viewDidEndLiveResize];
}

- (void)setFrameSize:(NSSize)size
{
    // NOTE: Instead of only acting when a frame was resized, we do some
    // updating each time a frame may be resized.  (At the moment, if we only
    // respond to actual frame changes then typing ":set lines=1000" twice in a
    // row will result in the vim view holding more rows than the can fit
    // inside the window.)
    [super setFrameSize:size];
    [self frameSizeMayHaveChanged:NO];
}

- (void)setFrameSizeKeepGUISize:(NSSize)size
{
    // NOTE: Instead of only acting when a frame was resized, we do some
    // updating each time a frame may be resized.  (At the moment, if we only
    // respond to actual frame changes then typing ":set lines=1000" twice in a
    // row will result in the vim view holding more rows than the can fit
    // inside the window.)
    [super setFrameSize:size];
    [self frameSizeMayHaveChanged:YES];
}

- (void)setFrame:(NSRect)frame
{
    // See comment in setFrameSize: above.
    [super setFrame:frame];
    [self frameSizeMayHaveChanged:NO];
}

- (BOOL)bottomScrollbarVisible
{
    for (MMScroller *scroller in _scrollbars) {
        if (scroller.type == MMScrollerTypeBottom && !scroller.isHidden) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)leftScrollbarVisible
{
    for (MMScroller *scroller in _scrollbars) {
        if (scroller.type == MMScrollerTypeLeft && !scroller.isHidden) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)rightScrollbarVisible
{
    for (MMScroller *scroller in _scrollbars) {
        if (scroller.type == MMScrollerTypeRight && !scroller.isHidden) {
            return YES;
        }
    }
    return NO;
}

- (void)placeScrollbars
{
    NSRect textViewFrame = _textView.frame;
    BOOL leftSbVisible = NO;
    BOOL rightSbVisible = NO;
    BOOL botSbVisible = NO;

    // HACK!  Find the lowest left&right vertical scrollbars This hack
    // continues further down.
    unsigned lowestLeftSbIdx = (unsigned)-1;
    unsigned lowestRightSbIdx = (unsigned)-1;
    unsigned rowMaxLeft = 0, rowMaxRight = 0;
    unsigned i = 0;
    for (MMScroller *scroller in _scrollbars) {
        if (!scroller.isHidden) {
            const NSRange range = scroller.range;
            if (scroller.type == MMScrollerTypeLeft && range.location >= rowMaxLeft) {
                rowMaxLeft = range.location;
                lowestLeftSbIdx = i;
                leftSbVisible = YES;
            } else if (scroller.type == MMScrollerTypeRight && range.location >= rowMaxRight) {
                rowMaxRight = range.location;
                lowestRightSbIdx = i;
                rightSbVisible = YES;
            } else if (scroller.type == MMScrollerTypeBottom) {
                botSbVisible = YES;
            }
        }
        i++;
    }

    // Place the scrollbars.
    for (MMScroller *scroller in _scrollbars) {
        if (scroller.isHidden) continue;

        NSRect rect;
#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7)
        CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
#else
        CGFloat scrollerWidth = NSScroller.scrollerWidth;
#endif
        if (scroller.type == MMScrollerTypeBottom) {
            rect = [_textView rectForColumnsInRange:scroller.range];
            rect.size.height = scrollerWidth;
            if (leftSbVisible) rect.origin.x += scrollerWidth;

            // HACK!  Make sure the horizontal scrollbar covers the text view
            // all the way to the right, otherwise it looks ugly when the user
            // drags the window to resize.
            float w = NSMaxX(textViewFrame) - NSMaxX(rect);
            if (w > 0) rect.size.width += w;

            // Make sure scrollbar rect is bounded by the text view frame.
            // Also leave some room for the resize indicator on the right in
            // case there is no right scrollbar.
            if (rect.origin.x < textViewFrame.origin.x)
                rect.origin.x = textViewFrame.origin.x;
            else if (rect.origin.x > NSMaxX(textViewFrame))
                rect.origin.x = NSMaxX(textViewFrame);
            if (NSMaxX(rect) > NSMaxX(textViewFrame))
                rect.size.width -= NSMaxX(rect) - NSMaxX(textViewFrame);
            if (!rightSbVisible)
                rect.size.width -= scrollerWidth;
            if (rect.size.width < 0)
                rect.size.width = 0;
        } else {
            rect = [_textView rectForRowsInRange:scroller.range];
            // Adjust for the fact that text layout is flipped.
            rect.origin.y = NSMaxY(textViewFrame) - rect.origin.y - rect.size.height;
            rect.size.width = scrollerWidth;
            if (scroller.type == MMScrollerTypeRight) rect.origin.x = NSMaxX(textViewFrame);

            // HACK!  Make sure the lowest vertical scrollbar covers the text
            // view all the way to the bottom.  This is done because Vim only
            // makes the scrollbar cover the (vim-)window it is associated with
            // and this means there is always an empty gap in the scrollbar
            // region next to the command line.
            // TODO!  Find a nicer way to do this.
            if (i == lowestLeftSbIdx || i == lowestRightSbIdx) {
                float h = rect.origin.y + rect.size.height - textViewFrame.origin.y;
                if (rect.size.height < h) {
                    rect.origin.y = textViewFrame.origin.y;
                    rect.size.height = h;
                }
            }

            // Vertical scrollers must not cover the resize box in the
            // bottom-right corner of the window.
            if (self.window.showsResizeIndicator && rect.origin.y < scrollerWidth) {
                rect.size.height -= scrollerWidth - rect.origin.y;
                rect.origin.y = scrollerWidth;
            }

            // Make sure scrollbar rect is bounded by the text view frame.
            if (rect.origin.y < textViewFrame.origin.y) {
                rect.size.height -= textViewFrame.origin.y - rect.origin.y;
                rect.origin.y = textViewFrame.origin.y;
            } else if (rect.origin.y > NSMaxY(textViewFrame))
                rect.origin.y = NSMaxY(textViewFrame);
            if (NSMaxY(rect) > NSMaxY(textViewFrame))
                rect.size.height -= NSMaxY(rect) - NSMaxY(textViewFrame);
            if (rect.size.height < 0)
                rect.size.height = 0;
        }

        const NSRect oldRect = scroller.frame;
        if (!NSEqualRects(oldRect, rect)) {
            scroller.frame = rect;
            // Clear behind the old scroller frame, or parts of the old
            // scroller might still be visible after setFrame:.
            self.window.contentView.needsDisplayInRect = oldRect;
            scroller.needsDisplay = YES;
        }
    }

    // HACK: If there is no bottom or right scrollbar the resize indicator will
    // cover the bottom-right corner of the text view so tell NSWindow not to
    // draw it in this situation.
    self.window.showsResizeIndicator = (rightSbVisible || botSbVisible);
}

- (NSUInteger)representedIndexOfTabViewItem:(NSTabViewItem *)item
{
    return [_tabBarControl.representedTabViewItems indexOfObject:item];
}

- (MMScroller *)scrollbarForIdentifier:(int32_t)identifier index:(unsigned *)outIndex
{
    unsigned i = 0;
    for (MMScroller *scroller in _scrollbars) {
        if (scroller.identifier == identifier) {
            if (outIndex) *outIndex = i;
            return scroller;
        }
        ++i;
    }
    return nil;
}

- (NSSize)vimViewSizeForTextViewSize:(NSSize)textViewSize
{
    NSSize size = textViewSize;
#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7)
    CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
#else
    CGFloat scrollerWidth = NSScroller.scrollerWidth;
#endif

    if (!_tabBarControl.isHidden)
        size.height += _tabBarControl.frame.size.height;

    if ([self bottomScrollbarVisible])
        size.height += scrollerWidth;
    if ([self leftScrollbarVisible])
        size.width += scrollerWidth;
    if ([self rightScrollbarVisible])
        size.width += scrollerWidth;

    return size;
}

- (NSRect)textViewRectForVimViewSize:(NSSize)contentSize
{
    NSRect rect = {NSZeroPoint, contentSize};
#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7)
    CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
#else
    CGFloat scrollerWidth = NSScroller.scrollerWidth;
#endif

    if (!_tabBarControl.isHidden)
        rect.size.height -= _tabBarControl.frame.size.height;

    if ([self bottomScrollbarVisible]) {
        rect.size.height -= scrollerWidth;
        rect.origin.y += scrollerWidth;
    }
    if ([self leftScrollbarVisible]) {
        rect.size.width -= scrollerWidth;
        rect.origin.x += scrollerWidth;
    }
    if ([self rightScrollbarVisible])
        rect.size.width -= scrollerWidth;

    return rect;
}

- (void)frameSizeMayHaveChanged:(BOOL)keepGUISize
{
    // NOTE: Whenever a call is made that may have changed the frame size we
    // take the opportunity to make sure all subviews are in place and that the
    // (rows,columns) are constrained to lie inside the new frame.  We not only
    // do this when the frame really has changed since it is possible to modify
    // the number of (rows,columns) without changing the frame size.

    // Give all superfluous space to the text view. It might be smaller or
    // larger than it wants to be, but this is needed during live resizing.
    _textView.frame = [self textViewRectForVimViewSize:self.frame.size];

    [self placeScrollbars];

    // It is possible that the current number of (rows,columns) is too big or
    // too small to fit the new frame.  If so, notify Vim that the text
    // dimensions should change, but don't actually change the number of
    // (rows,columns).  These numbers may only change when Vim initiates the
    // change (as opposed to the user dragging the window resizer, for
    // example).
    //
    // Note that the message sent to Vim depends on whether we're in
    // a live resize or not -- this is necessary to avoid the window jittering
    // when the user drags to resize.
    int constrained[2];
    [_textView constrainRows:&constrained[0] columns:&constrained[1] toSize:_textView.frame.size];

    const MMPoint maxSize = _textView.maxSize;

    if (constrained[0] != _textView.maxSize.row || constrained[1] != _textView.maxSize.col) {
        NSData *data = [NSData dataWithBytes:constrained length:sizeof(constrained)];
        const int msgid = self.inLiveResize ? LiveResizeMsgID
                                            : (keepGUISize ? SetTextDimensionsNoResizeWindowMsgID
                                                           : SetTextDimensionsMsgID);


        ASLogDebug(@"Notify Vim that text dimensions changed from %dx%d to %dx%d (%s)", maxSize.col, maxSize.row, constrained[1], constrained[0], MessageStrings[msgid]);

        [_vimController sendMessageNow:msgid data:data timeout:1];

        // We only want to set the window title if this resize came from
        // a live-resize, not (for example) setting 'columns' or 'lines'.
        if (self.inLiveResize) {
            self.window.title = [NSString stringWithFormat:@"%dx%d", constrained[1], constrained[0]];
        }
    }
}

@end // MMVimView (Private)
