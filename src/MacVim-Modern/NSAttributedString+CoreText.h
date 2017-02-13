#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface NSAttributedString (CoreTextExtension)

- (void)drawAtPoint:(CGPoint)point on:(CGContextRef)context;

/**
 * EXPERIMENTAL
 */
- (void)drawInRect:(CGRect)rect on:(CGContextRef)context;

@end
