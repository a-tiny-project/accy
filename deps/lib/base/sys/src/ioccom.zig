//! Request numbers in the ioctl encoding of BSD's <sys/ioccom.h>, which
//! darwin and FreeBSD share: the direction in the top three bits, the
//! argument's size in the next thirteen, then the group letter and the number.
const std = @import("std");

const parameter_mask: u32 = 0x1fff;
const no_argument: u32 = 0x20000000;
const out: u32 = 0x40000000;
const in: u32 = 0x80000000;

fn encode(direction: u32, group: u8, number: u8, size: usize) u32 {
    std.debug.assert(switch (direction) {
        no_argument, out, in => true,
        else => false,
    });
    std.debug.assert(std.ascii.isAlphabetic(group));
    std.debug.assert((direction == no_argument) == (size == 0));
    std.debug.assert(size <= parameter_mask);
    const length: u32 = @intCast(size);
    return direction | length << 16 | @as(u32, group) << 8 | number;
}

/// `_IO(group, number)`: the request carries no argument.
pub fn none(group: u8, number: u8) u32 {
    return encode(no_argument, group, number, 0);
}

/// `_IOR(group, number, type)`: the kernel writes `size` bytes to the argument.
pub fn read(group: u8, number: u8, size: usize) u32 {
    return encode(out, group, number, size);
}

/// `_IOW(group, number, type)`: the kernel reads `size` bytes from the argument.
pub fn write(group: u8, number: u8, size: usize) u32 {
    return encode(in, group, number, size);
}
