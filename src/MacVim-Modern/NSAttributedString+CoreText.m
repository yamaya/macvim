#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>

@implementation NSAttributedString (CoreTextExtension)

// FIXME: リガチャが無効にならない
- (void)drawAtPoint:(CGPoint)point on:(CGContextRef)context
{
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, point.x, point.y);
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)self);
    CTLineDraw(line, context);
    CFRelease(line);
}

// FIXME: 絵文字がレンダリングされない...
- (void)drawInRect:(CGRect)rect on:(CGContextRef)context
{
    static const CFRange zero = {0, 0};

    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)self);
    CGPathRef path = CGPathCreateWithRect(rect, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(framesetter, zero, path, NULL);

    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CTFrameDraw(frame, context);

    CFRelease(frame);
    CFRelease(path);
    CFRelease(framesetter);
}

@end
