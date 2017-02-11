#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface NSAttributedString (CoreTextExtension)

- (void)drawAtPoint:(CGPoint)point on:(CGContextRef)context;

@end
