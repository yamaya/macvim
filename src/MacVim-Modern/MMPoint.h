#import <Cocoa/Cocoa.h>

typedef struct {
    int row;
    int col;
} MMPoint;

inline BOOL MMPointIsEqual(const MMPoint x, const MMPoint y)
{
    return x.row == y.row && x.col == y.col;
}
