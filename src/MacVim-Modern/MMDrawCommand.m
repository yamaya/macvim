#import "MMDrawCommand.h"

@implementation MMDrawCommand {
    const Byte* _bytes;
}
@synthesize data = _data;

- (instancetype)initWithBytes:(const Byte *)bytes
{
    if (self = [super init]) != nil) {
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

- (const Byte *)pointerToCommand
{
    return _bytes + sizeof(int);
}

- (MMDrawCommandClearAll)parametersForClearAll
{
    MMDrawCommandClearAll command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (const MMDrawCommandClear *)parametersForClear
{
    return (const MMDrawCommandClear *) self.pointerToCommand;
}

- (MMDrawCommandDeleteLines)parametersForDeleteLines
{
    MMDrawCommandDeleteLines command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (MMDrawCommandDrawString)parametersForDrawString
{
    MMDrawCommandDrawString command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (MMDrawCommandInsertLines)parametersForInsertLines
{
    MMDrawCommandInsertLines command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (MMDrawCommandDrawCursor)parametersForDrawCursor
{
    MMDrawCommandDrawCursor command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (MMDrawCommandMoveCursor)parametersForMoveCursor
{
    MMDrawCommandMoveCursor command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (MMDrawCommandInvertRect)parametersForInvertRect
{
    MMDrawCommandInvertRect command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
}

- (MMDrawCommandDrawSign)parametersForDrawSign
{
    MMDrawCommandDrawSign command;
    memcpy(&command, self.pointerToCommand, sizeof(command));
    return command;
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
    const char* u8 = params.name.UTF8String;
    const int length = (int)strlen(u8) + 1;
    NSMutableData *data = NSMutableData.new;

    [data appendBytes:&type length:sizeof(int)];
    [data appendBytes:&length length:sizeof(int)];
    [data appendBytes:u8 length:length];
    [data appendBytes:&params.col length:sizeof(int)];
    [data appendBytes:&params.row length:sizeof(int)];
    [data appendBytes:&params.width length:sizeof(int)];
    [data appendBytes:&params.height length:sizeof(int)];

    return [[MMDrawCommand alloc] initWithData:data.copy];
}

@end
