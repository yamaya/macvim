#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>

@implementation NSAttributedString (CoreTextExtension)

- (void)drawAtPoint:(CGPoint)point on:(CGContextRef)context
{
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, point.x, point.y);
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)self);
    CTLineDraw(line, context);
    CFRelease(line);
}

@end
