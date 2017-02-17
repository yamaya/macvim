#import "MacVim.h"

#pragma pack(1)
typedef struct {} MMDrawCommandClearAll;
typedef struct { int color, row1, col1, row2, col2; } MMDrawCommandClear;
typedef struct { int color, row, count, scrollBottom, left, right; } MMDrawCommandDeleteLines;
typedef struct { unsigned bg, fg, sp; int row, col, cells, flags; int length; const Byte string[]; } MMDrawCommandDrawString;
typedef struct { int color, row, count, scrollBottom, left, right; } MMDrawCommandInsertLines;
typedef struct { int color, row, col, shape, fraction; } MMDrawCommandDrawCursor;
typedef struct { int row, col; } MMDrawCommandMoveCursor;
typedef struct { int row, col, numRows, numCols, invert; } MMDrawCommandInvertRect;
typedef struct { int row, col; int width, height; int length; const char name[]; } MMDrawCommandDrawSign;
#pragma pack()

/**
 */
@interface MMDrawCommand : NSObject

@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) int type;
@property (nonatomic, readonly) NSUInteger byteCount;

- (instancetype)initWithBytes:(const Byte *)bytes;

- (const MMDrawCommandClearAll *)parametersForClearAll;
- (const MMDrawCommandClear *)parametersForClear;
- (const MMDrawCommandDeleteLines *)parametersForDeleteLines;
- (const MMDrawCommandDrawString *)parametersForDrawString;
- (const MMDrawCommandInsertLines *)parametersForInsertLines;
- (const MMDrawCommandDrawCursor *)parametersForDrawCursor;
- (const MMDrawCommandMoveCursor *)parametersForMoveCursor;
- (const MMDrawCommandInvertRect *)parametersForInvertRect;
- (const MMDrawCommandDrawSign *)parametersForDrawSign;

+ (instancetype)commandWithClearAll:(MMDrawCommandClearAll)params;
+ (instancetype)commandWithClear:(MMDrawCommandClear)params;
+ (instancetype)commandWithDeleteLines:(MMDrawCommandDeleteLines)params;
+ (instancetype)commandWithDrawString:(MMDrawCommandDrawString)params;
+ (instancetype)commandWithInsertLines:(MMDrawCommandInsertLines)params;
+ (instancetype)commandWithDrawCursor:(MMDrawCommandDrawCursor)params;
+ (instancetype)commandWithMoveCursor:(MMDrawCommandMoveCursor)params;
+ (instancetype)commandWithInvertedRect:(MMDrawCommandInvertRect)params;
+ (instancetype)commandWithDrawSign:(MMDrawCommandDrawSign)params;

@end
