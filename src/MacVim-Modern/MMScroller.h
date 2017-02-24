#import <AppKit/AppKit.h>

// Scroller type; these must match SBAR_* in gui.h
typedef enum {
    MMScrollerTypeLeft = 0,
    MMScrollerTypeRight,
    MMScrollerTypeBottom
} MMScrollerType;

/**
 */
@interface MMScroller : NSScroller

@property (nonatomic, assign) NSRange range;
@property (nonatomic, readonly) MMScrollerType type;
@property (nonatomic, readonly) int32_t identifier;

- (instancetype)initWithIdentifier:(int32_t)ident type:(MMScrollerType)type;
@end
