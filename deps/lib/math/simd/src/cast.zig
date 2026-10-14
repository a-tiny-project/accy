const std = @import("std");

pub fn bitCast(comptime D: type, value: anytype) D.Vector {
    if (@bitSizeOf(@TypeOf(value)) / 8 != D.byte_count) {
        @compileError("bitCast requires equal source and destination byte sizes");
    }
    return @bitCast(value);
}

pub fn resizeBitCast(comptime D: type, value: anytype) D.Vector {
    return resize(D, value);
}

pub fn zeroExtendResizeBitCast(
    comptime DTo: type,
    comptime DFrom: type,
    value: DFrom.Vector,
) DTo.Vector {
    return resize(DTo, value);
}

fn resize(comptime D: type, value: anytype) D.Vector {
    const source_byte_count = @bitSizeOf(@TypeOf(value)) / 8;
    const SourceBytes = [source_byte_count]u8;
    const source: SourceBytes = @bitCast(value);
    var target: [D.byte_count]u8 = @splat(0);
    inline for (0..@min(source_byte_count, D.byte_count)) |index| {
        target[index] = source[index];
    }
    return @bitCast(target);
}
