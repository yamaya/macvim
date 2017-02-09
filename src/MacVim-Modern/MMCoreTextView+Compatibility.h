#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_8
#define kCTFontOrientationDefault kCTFontDefaultOrientation
#endif // MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_8

extern void CGContextSetFontSmoothingStyle(CGContextRef, int);
extern int CGContextGetFontSmoothingStyle(CGContextRef);
#define fontSmoothingStyleLight (2 << 3)

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_7
static void
CTFontDrawGlyphs(CTFontRef fontRef, const CGGlyph glyphs[], const CGPoint positions[], UniCharCount count, CGContextRef context)
{
    CGFontRef cgFontRef = CTFontCopyGraphicsFont(fontRef, NULL);
    CGContextSetFont(context, cgFontRef);
    CGContextShowGlyphsAtPositions(context, glyphs, positions, count);
    CGFontRelease(cgFontRef);
}
#endif // MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_7
