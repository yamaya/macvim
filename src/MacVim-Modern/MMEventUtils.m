#import "vim.h"
#import "MacVim.h"

int EventModifierFlagsToVimModMask(int flags)
{
    int mask = 0;

    if (flags & NSEventModifierFlagShift) mask |= MOD_MASK_SHIFT;
    if (flags & NSEventModifierFlagControl) mask |= MOD_MASK_CTRL;
    if (flags & NSEventModifierFlagOption) mask |= MOD_MASK_ALT;
    if (flags & NSEventModifierFlagCommand) mask |= MOD_MASK_CMD;

    return mask;
}

int EventModifierFlagsToVimMouseModMask(int flags)
{
    int mask = 0;

    if (flags & NSEventModifierFlagShift) mask |= MOUSE_SHIFT;
    if (flags & NSEventModifierFlagControl) mask |= MOUSE_CTRL;
    if (flags & NSEventModifierFlagOption) mask |= MOUSE_ALT;

    return mask;
}

int EventButtonNumberToVimMouseButton(int no)
{
    static const int button[] = {MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE};
    return (0 <= no && no < 3) ? button[no] : -1;
}
