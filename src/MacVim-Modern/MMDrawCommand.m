#import "MMDrawCommand.h"

@implementation MMDrawCommand {
    const Byte* _bytes;
}
@synthesize data = _data;

- (instancetype)initWithBytes:(const Byte *)bytes
{
    if ((self = [super init]) != nil) {
        _bytes = bytes;
    }
    return self;
}

- (instancetype)initWithType:(int)type bytes:(const void *)bytes length:(size_t)length
{
    if ((self = [super init]) != nil) {
        NSMutableData *data = NSMutableData.new;
        [data appendBytes:&type length:sizeof(int)];
        if (bytes && length != 0) {
            [data appendBytes:bytes length:length];
        }
        _data = data.copy;
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data;
{
    if ((self = [super init]) != nil) {
        _data = data;
    }
    return self;
}

- (int)type
{
    assert(_bytes);
    return *((int *)_bytes);
}

- (NSUInteger)byteCount
{
    NSUInteger n = sizeof(int) + self.byteCountOfParams;
    if (self.type == DrawStringDrawType) {
        const MMDrawCommandDrawString *p = self.parametersForDrawString;
        n += p->length;
    }
    else if (self.type == DrawSignDrawType) {
        const MMDrawCommandDrawSign *p = self.parametersForDrawSign;
        n += p->length;
    }
    return n;
}

- (const Byte *)pointerToCommand
{
    return _bytes + sizeof(int);
}

- (NSUInteger)byteCountOfParams
{
    switch (self.type) {
    case ClearAllDrawType: return sizeof(MMDrawCommandClearAll);
    case ClearBlockDrawType: return sizeof(MMDrawCommandClear);
    case DeleteLinesDrawType: return sizeof(MMDrawCommandDeleteLines);
    case DrawStringDrawType: return sizeof(MMDrawCommandDrawString);
    case InsertLinesDrawType: return sizeof(MMDrawCommandInsertLines);
    case DrawCursorDrawType:return sizeof(MMDrawCommandDrawCursor);
    case SetCursorPosDrawType:return sizeof(MMDrawCommandMoveCursor);
    case DrawInvertedRectDrawType:return sizeof(MMDrawCommandInvertRect);
    case DrawSignDrawType:return sizeof(MMDrawCommandDrawSign);
    }
    assert(false);
}

- (const MMDrawCommandClearAll *)parametersForClearAll
{
    return (const MMDrawCommandClearAll *)self.pointerToCommand;
}

- (const MMDrawCommandClear *)parametersForClear
{
    return (const MMDrawCommandClear *)self.pointerToCommand;
}

- (const MMDrawCommandDeleteLines *)parametersForDeleteLines
{
    return (const MMDrawCommandDeleteLines *)self.pointerToCommand;
}


- (const MMDrawCommandDrawString *)parametersForDrawString
{
    return (const MMDrawCommandDrawString *)self.pointerToCommand;
}

- (const MMDrawCommandInsertLines *)parametersForInsertLines
{
    return (const MMDrawCommandInsertLines *)self.pointerToCommand;
}

- (const MMDrawCommandDrawCursor *)parametersForDrawCursor
{
    return (const MMDrawCommandDrawCursor *)self.pointerToCommand;
}

- (const MMDrawCommandMoveCursor *)parametersForMoveCursor
{
    return (const MMDrawCommandMoveCursor *)self.pointerToCommand;
}

- (const MMDrawCommandInvertRect *)parametersForInvertRect
{
    return (const MMDrawCommandInvertRect *)self.pointerToCommand;
}

- (const MMDrawCommandDrawSign *)parametersForDrawSign
{
    return (const MMDrawCommandDrawSign *)self.pointerToCommand;
}

+ (instancetype)commandWithClearAll:(MMDrawCommandClearAll)params
{
    return [[MMDrawCommand alloc] initWithType:ClearAllDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithClear:(MMDrawCommandClear)params
{
    return [[MMDrawCommand alloc] initWithType:ClearBlockDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithDeleteLines:(MMDrawCommandDeleteLines)params
{
    return [[MMDrawCommand alloc] initWithType:DeleteLinesDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithDrawString:(MMDrawCommandDrawString)params
{
    const int type = DeleteLinesDrawType;
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&type length:sizeof(int)];
    [data appendBytes:&params.fg length:sizeof(unsigned)];
    [data appendBytes:&params.bg length:sizeof(unsigned)];
    [data appendBytes:&params.sp length:sizeof(unsigned)];
    [data appendBytes:&params.row length:sizeof(int)];
    [data appendBytes:&params.col length:sizeof(int)];
    [data appendBytes:&params.cells length:sizeof(int)];
    [data appendBytes:&params.flags length:sizeof(int)];
    [data appendBytes:&params.length length:sizeof(int)];
    [data appendBytes:params.string length:params.length];

    return [[MMDrawCommand alloc] initWithData:data.copy];
}

+ (instancetype)commandWithInsertLines:(MMDrawCommandInsertLines)params
{
    return [[MMDrawCommand alloc] initWithType:InsertLinesDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithDrawCursor:(MMDrawCommandDrawCursor)params
{
    return [[MMDrawCommand alloc] initWithType:DrawCursorDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithMoveCursor:(MMDrawCommandMoveCursor)params
{
    return [[MMDrawCommand alloc] initWithType:SetCursorPosDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithInvertedRect:(MMDrawCommandInvertRect)params
{
    return [[MMDrawCommand alloc] initWithType:DrawInvertedRectDrawType bytes:&params length:sizeof(params)];
}

+ (instancetype)commandWithDrawSign:(MMDrawCommandDrawSign)params
{
    const int type = DrawSignDrawType;
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&type length:sizeof(int)];
    [data appendBytes:&params.length length:sizeof(int)];
    [data appendBytes:&params.name length:params.length];
    [data appendBytes:&params.col length:sizeof(int)];
    [data appendBytes:&params.row length:sizeof(int)];
    [data appendBytes:&params.width length:sizeof(int)];
    [data appendBytes:&params.height length:sizeof(int)];

    return [[MMDrawCommand alloc] initWithData:data.copy];
}

@end
