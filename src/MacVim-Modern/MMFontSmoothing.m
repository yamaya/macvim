#import "MMFontSmoothing.h"
#import "MMCoreTextView+Compatibility.h"

@implementation MMFontSmoothing
{
  int _style;
}
@synthesize context = _context, enabled = _enabled;

+ (instancetype)fontSmoothingEnabled:(BOOL)enabled on:(CGContextRef)context
{
    return [[MMFontSmoothing alloc] initWithContext:context enabled:enabled];
}

- (instancetype)initWithContext:(CGContextRef)context enabled:(BOOL)enabled
{
    if ((self = [super init]) != nil) {
        _context = context;
        _enabled = enabled;
        if (_enabled) [self setStyle:fontSmoothingStyleLight];
    }
    return self;
}

- (void)dealloc
{
    [self restore];
}

- (void)setStyle:(int)style
{
    _style = CGContextGetFontSmoothingStyle(_context);
    CGContextSetFontSmoothingStyle(_context, style);
}

- (void)restore
{
    if (_enabled) CGContextSetFontSmoothingStyle(_context, _style);
}

@end
