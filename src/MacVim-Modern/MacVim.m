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
 * MacVim.m:  Code shared between Vim and MacVim.
 */

#import "MacVim.h"


const char * const MessageStrings[] = 
{
    "INVALID MESSAGE ID",
    "OpenWindowMsgID",
    "KeyDownMsgID",
    "BatchDrawMsgID",
    "SelectTabMsgID",
    "CloseTabMsgID",
    "AddNewTabMsgID",
    "DraggedTabMsgID",
    "UpdateTabBarMsgID",
    "ShowTabBarMsgID",
    "HideTabBarMsgID",
    "SetTextRowsMsgID",
    "SetTextColumnsMsgID",
    "SetTextDimensionsMsgID",
    "SetTextDimensionsNoResizeWindowMsgID",
    "LiveResizeMsgID",
    "SetTextDimensionsReplyMsgID",
    "ResizeViewMsgID",
    "SetWindowTitleMsgID",
    "ScrollWheelMsgID",
    "MouseDownMsgID",
    "MouseUpMsgID",
    "MouseDraggedMsgID",
    "FlushQueueMsgID",
    "AddMenuMsgID",
    "AddMenuItemMsgID",
    "RemoveMenuItemMsgID",
    "EnableMenuItemMsgID",
    "ExecuteMenuMsgID",
    "ShowToolbarMsgID",
    "ToggleToolbarMsgID",
    "CreateScrollbarMsgID",
    "DestroyScrollbarMsgID",
    "ShowScrollbarMsgID",
    "SetScrollbarPositionMsgID",
    "SetScrollbarThumbMsgID",
    "ScrollbarEventMsgID",
    "SetFontMsgID",
    "SetWideFontMsgID",
    "VimShouldCloseMsgID",
    "SetDefaultColorsMsgID",
    "ExecuteActionMsgID",
    "DropFilesMsgID",
    "DropStringMsgID",
    "ShowPopupMenuMsgID",
    "GotFocusMsgID",
    "LostFocusMsgID",
    "MouseMovedMsgID",
    "SetMouseShapeMsgID",
    "AdjustLinespaceMsgID",
    "ActivateMsgID",
    "SetServerNameMsgID",
    "EnterFullScreenMsgID",
    "LeaveFullScreenMsgID",
    "SetBuffersModifiedMsgID",
    "AddInputMsgID",
    "SetPreEditPositionMsgID",
    "TerminateNowMsgID",
    "XcodeModMsgID",
    "EnableAntialiasMsgID",
    "DisableAntialiasMsgID",
    "SetVimStateMsgID",
    "SetDocumentFilenameMsgID",
    "OpenWithArgumentsMsgID",
    "CloseWindowMsgID",
    "SetFullScreenColorMsgID",
    "ShowFindReplaceDialogMsgID",
    "FindReplaceMsgID",
    "ActivateKeyScriptMsgID",
    "DeactivateKeyScriptMsgID",
    "EnableImControlMsgID",
    "DisableImControlMsgID",
    "ActivatedImMsgID",
    "DeactivatedImMsgID",
    "BrowseForFileMsgID",
    "ShowDialogMsgID",
    "SetMarkedTextMsgID",
    "ZoomMsgID",
    "SetWindowPositionMsgID",
    "DeleteSignMsgID",
    "SetTooltipMsgID",
    "SetTooltipDelayMsgID",
    "GestureMsgID",
    "AddToMRUMsgID",
    "BackingPropertiesChangedMsgID",
    "SetBlurRadiusMsgID",
    "EnableLigaturesMsgID",
    "DisableLigaturesMsgID",
    "EnableThinStrokesMsgID",
    "DisableThinStrokesMsgID",
    "END OF MESSAGE IDs"     // NOTE: Must be last!
};

NSString *const MMLogLevelKey           = @"MMLogLevel";
NSString *const MMLogToStdErrKey        = @"MMLogToStdErr";
NSString *const MMNoWindowKey           = @"MMNoWindow";
NSString *const MMShareFindPboardKey    = @"MMShareFindPboard";
NSString *const MMAutosaveRowsKey       = @"MMAutosaveRows";
NSString *const MMAutosaveColumnsKey    = @"MMAutosaveColumns";
NSString *const VimFindPboardType       = @"VimFindPboardType";

int ASLogLevel = MM_ASL_LEVEL_DEFAULT;

// Create a string holding the labels of all messages in message queue for
// debugging purposes (condense some messages since there may typically be LOTS
// of them on a queue).
extern NSString *
debugStringForMessageQueue(NSArray *queue)
{
    NSMutableString *s = NSMutableString.new;
    NSUInteger const count = queue.count;
    int item = 0, menu = 0, enable = 0, remove = 0;
    int sets = 0, sett = 0, shows = 0, cres = 0, dess = 0;
    for (NSUInteger i = 0; i < count; i += 2) {
        NSData *value = queue[i];
        const int msgid = *((int *)value.bytes);
        if (msgid < 1 || msgid >= LastMsgID)
            continue;
        if (msgid == AddMenuItemMsgID) ++item;
        else if (msgid == AddMenuMsgID) ++menu;
        else if (msgid == EnableMenuItemMsgID) ++enable;
        else if (msgid == RemoveMenuItemMsgID) ++remove;
        else if (msgid == SetScrollbarPositionMsgID) ++sets;
        else if (msgid == SetScrollbarThumbMsgID) ++sett;
        else if (msgid == ShowScrollbarMsgID) ++shows;
        else if (msgid == CreateScrollbarMsgID) ++cres;
        else if (msgid == DestroyScrollbarMsgID) ++dess;
        else [s appendFormat:@"%s ", MessageStrings[msgid]];
    }
    if (item > 0) [s appendFormat:@"AddMenuItemMsgID(%d) ", item];
    if (menu > 0) [s appendFormat:@"AddMenuMsgID(%d) ", menu];
    if (enable > 0) [s appendFormat:@"EnableMenuItemMsgID(%d) ", enable];
    if (remove > 0) [s appendFormat:@"RemoveMenuItemMsgID(%d) ", remove];
    if (sets > 0) [s appendFormat:@"SetScrollbarPositionMsgID(%d) ", sets];
    if (sett > 0) [s appendFormat:@"SetScrollbarThumbMsgID(%d) ", sett];
    if (shows > 0) [s appendFormat:@"ShowScrollbarMsgID(%d) ", shows];
    if (cres > 0) [s appendFormat:@"CreateScrollbarMsgID(%d) ", cres];
    if (dess > 0) [s appendFormat:@"DestroyScrollbarMsgID(%d) ", dess];

    return s;
}


@implementation NSString (MMExtras)

- (NSString *)stringByEscapingSpecialFilenameCharacters
{
    // NOTE: This code assumes that no characters already have been escaped.
    NSMutableString *string = self.mutableCopy;

    [string replaceOccurrencesOfString:@"\\"
                            withString:@"\\\\"
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@" "
                            withString:@"\\ "
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"\t"
                            withString:@"\\\t "
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"%"
                            withString:@"\\%"
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"#"
                            withString:@"\\#"
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"|"
                            withString:@"\\|"
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"\""
                            withString:@"\\\""
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    return string;
}

- (NSString *)stringByRemovingFindPatterns
{
    // Remove some common patterns added to search strings that other apps are
    // not aware of.

    NSMutableString *string = self.mutableCopy;

    // Added when doing * search
    [string replaceOccurrencesOfString:@"\\<"
                            withString:@""
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"\\>"
                            withString:@""
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    // \V = match whole word
    [string replaceOccurrencesOfString:@"\\V"
                            withString:@""
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    // \c = case insensitive, \C = case sensitive
    [string replaceOccurrencesOfString:@"\\c"
                            withString:@""
                               options:NSCaseInsensitiveSearch | NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    return string;
}

- (NSString *)stringBySanitizingSpotlightSearch
{
    // Limit length of search text
    const NSUInteger len = MIN(self.length, 1024);
    if (len == 0) return self;

    NSMutableString *string = [[self substringToIndex:len] mutableCopy];

    // Ignore strings with control characters
    NSRange r = [string rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet];
    if (r.location != NSNotFound)
        return nil;

    // Replace ' with '' since it is used as a string delimeter in the command
    // that we pass on to Vim to perform the search.
    [string replaceOccurrencesOfString:@"'"
                            withString:@"''"
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];

    // Replace \ with \\ to avoid Vim interpreting it as the beginning of a
    // character class.
    [string replaceOccurrencesOfString:@"\\"
                            withString:@"\\\\"
                               options:NSLiteralSearch
                                 range:NSMakeRange(0, string.length)];
    return string;
}

@end // NSString (MMExtras)


@implementation NSColor (MMExtras)

+ (NSColor *)colorWithRgbInt:(unsigned)rgb
{
    const float r = ((rgb >> 16) & 0xff) / 255.0f;
    const float g = ((rgb >>  8) & 0xff) / 255.0f;
    const float b = (rgb         & 0xff) / 255.0f;

    return [NSColor colorWithDeviceRed:r green:g blue:b alpha:1];
}

+ (NSColor *)colorWithArgbInt:(unsigned)argb
{
    const float a = ((argb >> 24) & 0xff) / 255.0f;
    const float r = ((argb >> 16) & 0xff) / 255.0f;
    const float g = ((argb >>  8) & 0xff) / 255.0f;
    const float b = (argb & 0xff        ) / 255.0f;

    return [NSColor colorWithDeviceRed:r green:g blue:b alpha:a];
}

@end // NSColor (MMExtras)


@implementation NSDictionary (MMExtras)

+ (id)dictionaryWithData:(NSData *)data
{
#if MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_10
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
#else
    id plist = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
#endif
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

- (NSData *)dictionaryAsData
{
#if MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_10
    return [NSPropertyListSerialization dataWithPropertyList:self format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
#else
    return [NSPropertyListSerialization dataFromPropertyList:self format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
#endif
}

@end



@implementation NSMutableDictionary (MMExtras)

+ (id)dictionaryWithData:(NSData *)data
{
#if MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_10
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL];
#else
    id plist = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:NULL];
#endif
    return [plist isKindOfClass:NSMutableDictionary.class] ? plist : nil;
}

@end


void
ASLInit()
{
    // Allow for changing the log level via user defaults.  If no key is found
    // the default log level will be used (which for ASL is to log everything
    // up to ASL_LEVEL_NOTICE).  This key is an integer which corresponds to
    // the ASL_LEVEL_* macros (0 is most severe, 7 is debug level).
    const id logLevelObj = [NSUserDefaults.standardUserDefaults objectForKey:(NSString *)MMLogLevelKey];
    if (logLevelObj) {
        int logLevel = [logLevelObj intValue];
        if (logLevel < 0) logLevel = 0;
#if defined(MM_USE_ASL)
        if (logLevel > ASL_LEVEL_DEBUG) logLevel = ASL_LEVEL_DEBUG;
        asl_set_filter(NULL, ASL_FILTER_MASK_UPTO(logLevel));
#else
        switch (logLevel) {
        case 0: case 1: case 2:
            logLevel = OS_LOG_TYPE_FAULT; break;
        case 3:
            logLevel = OS_LOG_TYPE_ERROR; break;
        case 4: case 5:
            logLevel = OS_LOG_TYPE_DEFAULT; break;
        case 6:
            logLevel = OS_LOG_TYPE_INFO; break;
        default:
            logLevel = OS_LOG_TYPE_DEBUG; break;
        }
#endif
        ASLogLevel = logLevel;
    }

#if defined(MM_USE_ASL)
    // Allow for changing whether a copy of each log should be sent to stderr
    // (this defaults to NO if this key is missing in the user defaults
    // database).  The above filter mask is applied to logs going to stderr,
    // contrary to how "vanilla" ASL works.
    if ([NSUserDefaults.standardUserDefaults boolForKey:MMLogToStdErrKey])
        asl_add_log_file(NULL, 2);  // The file descriptor for stderr is 2
#endif
}
