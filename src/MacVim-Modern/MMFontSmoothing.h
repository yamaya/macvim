#import <Cocoa/Cocoa.h>

@interface MMFontSmoothing : NSObject

@property (nonatomic, readonly) CGContextRef context;
@property (nonatomic, readonly) BOOL enabled;

- (instancetype)initWithContext:(CGContextRef)context enabled:(BOOL)enabled;

- (void)restore;

+ (instancetype)fontSmoothingEnabled:(BOOL)enabled on:(CGContextRef)context;

@end
