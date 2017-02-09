#import "MMCoreTextRenderer.h"

static CTFontRef
LookupFont(NSMutableArray *fontCache, const UniChar *chars, UniCharCount charCount, CTFontRef currFontRef)
{
    CGGlyph glyphs[charCount];
     
    // See if font in cache can draw at least one character
    for (NSFont *font in fontCache) {
        if (CTFontGetGlyphsForCharacters((CTFontRef)font, chars, glyphs, charCount)) {
            return (__bridge_retained CTFontRef)font;
        }
    }
     
    // Ask Core Text for a font (can be *very* slow, which is why we cache
    // fonts in the first place)
    CFStringRef strRef = CFStringCreateWithCharacters(NULL, chars, charCount);
    CTFontRef newFontRef = CTFontCreateForString(currFontRef, strRef, (CFRange){0, charCount});
    CFRelease(strRef);
     
    // Verify the font can actually convert all the glyphs.
    if (!CTFontGetGlyphsForCharacters(newFontRef, chars, glyphs, charCount)) return nil;
     
    if (newFontRef) [fontCache addObject:(__bridge NSFont *)newFontRef];
     
    return newFontRef;
}

static CFAttributedStringRef
CFLigaturedAttributedStringCreate(NSString *string, const CTFontRef font)
{
    return CFAttributedStringCreate(NULL, (CFStringRef)string, (CFDictionaryRef)@{
        (NSString *)kCTFontAttributeName: (__bridge NSFont*)font,
        (NSString *)kCTLigatureAttributeName: @YES,
    });
}

static UniCharCount
GetGlyphsAndAdvances(CTLineRef line, CGGlyph *glyphs, CGSize *advances, UniCharCount length)
{
    NSArray *glyphRuns = (NSArray *)CTLineGetGlyphRuns(line);
     
    // get a hold on the actual character widths and glyphs in line
    UniCharCount offset = 0;
    for (id item in glyphRuns) {
        CTRunRef run  = (__bridge CTRunRef)item;
        CFIndex count = CTRunGetGlyphCount(run);
         
        if (count > 0 && count - offset > length) count = length - offset;
         
        const CFRange range = {0, count};
         
        if (glyphs) CTRunGetGlyphs(run, range, &glyphs[offset]);
        if (advances) CTRunGetAdvances(run, range, &advances[offset]);
         
        offset += count;
         
        if (offset >= length) break;
    }
     
    return offset;
}

static UniCharCount
gatherGlyphs(CGGlyph glyphs[], UniCharCount count)
{
    // Gather scattered glyphs that was happended by Surrogate pair chars
    CFIndex pos = 0;
    for (CFIndex i = 0; i < count; ++i) {
        if (glyphs[i] != 0) {
            glyphs[pos++] = glyphs[i];
        }
    }
    return pos;
}

// tricky part: compare both advance ranges and chomp positions which are
// covered by a single ligature while keeping glyphs not in the ligature
// font.
#define fequal(a, b)    (fabs((a) - (b)) < FLT_EPSILON)
#define fless(a, b)     ((a) - (b) < FLT_EPSILON) && (fabs((a) - (b)) > FLT_EPSILON)

static UniCharCount
ligatureGlyphsForChars(const unichar *chars, CGGlyph *glyphs, CGPoint *positions, UniCharCount length, CTFontRef font)
{
    // CoreText has no simple wait of retrieving a ligature for a set of
    // UniChars. The way proposed on the CoreText ML is to convert the text to
    // an attributed string, create a CTLine from it and retrieve the Glyphs
    // from the CTRuns in it.
    CGGlyph refGlyphs[length];
    CGPoint refPositions[length];
     
    memcpy(refGlyphs, glyphs, sizeof(CGGlyph) * length);
    memcpy(refPositions, positions, sizeof(CGSize) * length);
     
    memset(glyphs, 0, sizeof(CGGlyph) * length);
     
    NSString *plainText = [NSString stringWithCharacters:chars length:length];
    CFAttributedStringRef ligatureText = CFLigaturedAttributedStringCreate(plainText, font);
     
    CTLineRef lineRef = CTLineCreateWithAttributedString(ligatureText);
     
    CGSize ligatureRanges[length], regularRanges[length];
     
    // get the (ligature)glyphs and advances for the new text
    UniCharCount offset = GetGlyphsAndAdvances(lineRef, glyphs, ligatureRanges, length);
    // fetch the advances for the base text
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, refGlyphs, regularRanges, length);
     
    CFRelease(ligatureText);
    CFRelease(lineRef);
     
    for (CFIndex i = 0, skip = 0; i < offset && skip + i < length; ++i) {
        memcpy(&positions[i], &refPositions[skip + i], sizeof(CGSize));
         
        if (fequal(ligatureRanges[i].width, regularRanges[skip + i].width)) {
            // [mostly] same width
            continue;
        } else if (fless(ligatureRanges[i].width, regularRanges[skip + i].width)) {
            // original is wider than our result - use the original glyph
            // FIXME: this is currently the only way to detect emoji (except
            // for 'glyph[i] == 5')
            glyphs[i] = refGlyphs[skip + i];
            continue;
        }
         
        // no, that's a ligature
        // count how many positions this glyph would take up in the base text
        CFIndex j = 0;
        float width = ceil(regularRanges[skip + i].width);
         
        while ((int)width < (int)ligatureRanges[i].width && skip + i + j < length) {
            width += ceil(regularRanges[++j + skip + i].width);
        }
        skip += j;
    }
     
    // as ligatures combine characters it is required to adjust the
    // original length value
    return offset;
}

#undef fless
#undef fequal

void RecurseDraw(const unichar *chars, CGGlyph *glyphs, CGPoint *positions, UniCharCount length, CGContextRef context, CTFontRef fontRef, NSMutableArray *fontCache, BOOL useLigatures)
{
    if (CTFontGetGlyphsForCharacters(fontRef, chars, glyphs, length)) {
        // All chars were mapped to glyphs, so draw all at once and return.
        if (useLigatures && length > 1) {
            length = ligatureGlyphsForChars(chars, glyphs, positions, length, fontRef);
        } else {
            // only fixup surrogate pairs if we're not using ligatures
            length = gatherGlyphs(glyphs, length);
        }
         
        CTFontDrawGlyphs(fontRef, glyphs, positions, length, context);
        return;
    }

    CGGlyph *glyphsEnd = glyphs + length, *g = glyphs;
    CGPoint *p = positions;
    const unichar *c = chars;
    while (glyphs < glyphsEnd) {
        if (*g) {
            // Draw as many consecutive glyphs as possible in the current font
            // (if a glyph is 0 that means it does not exist in the current
            // font).
            BOOL surrogatePair = NO;
            while (*g && g < glyphsEnd) {
                if (CFStringIsSurrogateHighCharacter(*c)) {
                    surrogatePair = YES;
                    g += 2;
                    c += 2;
                } else {
                    ++g;
                    ++c;
                }
                ++p;
            }
             
            int count = g-glyphs;
            if (surrogatePair) count = gatherGlyphs(glyphs, count);
            CTFontDrawGlyphs(fontRef, glyphs, positions, count, context);
        } else {
            // Skip past as many consecutive chars as possible which cannot be
            // drawn in the current font.
            while (0 == *g && g < glyphsEnd) {
                if (CFStringIsSurrogateHighCharacter(*c)) {
                    g += 2;
                    c += 2;
                } else {
                    ++g;
                    ++c;
                }
                ++p;
            }
             
            // Try to find a fallback font that can render the entire
            // invalid range. If that fails, repeatedly halve the attempted
            // range until a font is found.
            const UniCharCount count = c - chars;
            UniCharCount attemptedCount = count;
            CTFontRef fallbackFontRef = nil;
            while (!fallbackFontRef && attemptedCount > 0) {
                fallbackFontRef = LookupFont(fontCache, chars, attemptedCount, fontRef);
                if (!fallbackFontRef) attemptedCount /= 2;
            }
            if (!fallbackFontRef)
                return;
             
            RecurseDraw(chars, glyphs, positions, attemptedCount, context, fallbackFontRef, fontCache, useLigatures);
             
            // If only a portion of the invalid range was rendered above,
            // the remaining range needs to be attempted by subsequent
            // iterations of the draw loop.
            c -= count - attemptedCount;
            g -= count - attemptedCount;
            p -= count - attemptedCount;
             
            CFRelease(fallbackFontRef);
        }
         
        if (glyphs == g) {
           // No valid chars in the glyphs. Exit from the possible infinite
           // recursive call.
           break;
        }
         
        chars = c;
        glyphs = g;
        positions = p;
    }
}
