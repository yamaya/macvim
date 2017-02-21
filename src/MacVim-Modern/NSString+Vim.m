#import "NSString+Vim.h"

@implementation NSString (VimStrings)

+ (instancetype)stringWithVimString:(char_u *)vimString
{
    // This method ensures a non-nil string is returned.  If 'vimString' cannot be
    // converted to a utf-8 string it is assumed to be latin-1.  If conversion
    // still fails an empty NSString is returned.
    NSString *string = nil;
    if (vimString) {
#ifdef FEAT_MBYTE
        vimString = CONVERT_TO_UTF8(vimString);
#endif
        string = [NSString stringWithUTF8String:(char *)vimString];
        if (!string) {
            // HACK! Apparently 'vimString' is not a valid utf-8 string, maybe it is
            // latin-1?
            string = [NSString stringWithCString:(char *)vimString encoding:NSISOLatin1StringEncoding];
        }
#ifdef FEAT_MBYTE
        CONVERT_TO_UTF8_FREE(vimString);
#endif
    }

    return string ?: NSString.new;
}

- (char_u *)vimStringSave
{
    char_u *cstring = (char_u *)self.UTF8String;

#ifdef FEAT_MBYTE
    cstring = CONVERT_FROM_UTF8(cstring);
#endif
    char_u *ret = vim_strsave(cstring);
#ifdef FEAT_MBYTE
    CONVERT_FROM_UTF8_FREE(cstring);
#endif

    return ret;
}

@end // NSString (VimStrings)
