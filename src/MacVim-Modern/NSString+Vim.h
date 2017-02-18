#import <Foundation/Foundation.h>
#import "vim.h"

@interface NSString (VimStrings)

+ (instancetype)stringWithVimString:(char_u *)vimString;
- (char_u *)vimStringSave;

@end

