#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>

extern void RecurseDraw(const unichar *chars, CGGlyph *glyphs, CGPoint *positions, UniCharCount length, CGContextRef context, CTFontRef fontRef, NSMutableArray *fontCache, BOOL useLigatures);
