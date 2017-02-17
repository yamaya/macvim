#import "MacVim.h"

#pragma pack(1)
typedef struct {} MMDrawCommandClearAll;
typedef struct { int row1, col1, row2, col2; } MMDrawCommandClear;
typedef struct { int row, count, scrollBottom, left, right; } MMDrawCommandDeleteLines;
typedef struct { Byte *string; int length; int row, col, cells; int fg, bg, sp, flags; } MMDrawCommandDrawString;
typedef struct { int row, count, scrollBottom, left, right; } MMDrawCommandInsertLines;
typedef struct { int row, col, shape, fraction, color; } MMDrawCommandDrawCursor;
typedef struct { int row, col; } MMDrawCommandMoveCursor;
typedef struct { int row, col, numRows, numCols, invert; } MMDrawCommandInvertRect;
typedef struct { NSString *name; int row, col; int width, height; } MMDrawCommandDrawSign;
#pragma pack()

@interface MMDrawCommand : NSObject
@property (nonatomic, readonly) NSData *data;

- (instancetype)initWithBytes:(const Byte *)bytes;

- (MMDrawCommandClearAll)parametersForClearAll;
- (MMDrawCommandClear)parametersForClear;
- (MMDrawCommandDeleteLines)parametersForDeleteLines;

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
