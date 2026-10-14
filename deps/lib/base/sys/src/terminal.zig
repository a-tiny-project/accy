const std = @import("std");
const builtin = @import("builtin");

const capabilities = @import("capabilities.zig");
const env = @import("env.zig");
const fd = @import("fd.zig");
const ioccom = @import("ioccom.zig");
const pty = @import("pty.zig");
const posix = std.posix;

/// The request that sets a terminal's window size. Darwin's std declares only
/// the query, so sys encodes the set as <sys/ttycom.h> does.
const set_window_size = if (builtin.os.tag.isDarwin())
    @as(c_int, @bitCast(ioccom.write('t', 103, @sizeOf(posix.winsize))))
else
    posix.T.IOCSWINSZ;

// The encoder must give std's own darwin query request.
comptime {
    if (builtin.os.tag.isDarwin()) {
        std.debug.assert(ioccom.read('t', 104, @sizeOf(posix.winsize)) == posix.T.IOCGWINSZ);
    }
}

pub const required_capabilities = capabilities.host(&.{ .descriptors, .environment, .terminal });

pub const Size = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16,
    y_pixel: u16,
};

pub const Attributes = posix.termios;
pub const AttributeAction = posix.TCSA;
pub const AttributeQueryError = posix.TermiosGetError || error{UnsupportedPlatform};
pub const AttributeApplyError = posix.TermiosSetError || error{UnsupportedPlatform};
pub const SizeError = error{ UnsupportedPlatform, QueryFailed, ApplyFailed };

pub fn querySize(file: std.Io.File) ?Size {
    return queryDescriptorSize(file.handle);
}

pub fn isTty(file: std.Io.File) bool {
    if (file.isTty(std.Options.debug_io) catch false) return true;
    return isDescriptorTty(file.handle);
}

pub fn isDescriptorTty(descriptor: fd.Descriptor) bool {
    if (!supportsPosixTerminalIo()) return false;
    _ = posix.tcgetattr(descriptor) catch return false;
    return true;
}

pub fn queryDescriptorSize(descriptor: fd.Descriptor) ?Size {
    if (!supportsPosixTerminalIo()) return null;

    var winsize: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const err = posix.system.ioctl(descriptor, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (posix.errno(err) != .SUCCESS) return null;

    return .{
        .rows = winsize.row,
        .cols = winsize.col,
        .x_pixel = winsize.xpixel,
        .y_pixel = winsize.ypixel,
    };
}

pub fn setDescriptorSize(descriptor: fd.Descriptor, size: Size) SizeError!void {
    if (!supportsPosixTerminalIo()) return error.UnsupportedPlatform;
    var winsize = posix.winsize{
        .row = size.rows,
        .col = size.cols,
        .xpixel = size.x_pixel,
        .ypixel = size.y_pixel,
    };
    const result = posix.system.ioctl(
        descriptor,
        set_window_size,
        @intFromPtr(&winsize),
    );
    if (posix.errno(result) != .SUCCESS) return error.ApplyFailed;
}

pub fn getAttributes(descriptor: fd.Descriptor) AttributeQueryError!Attributes {
    if (!supportsPosixTerminalIo()) return error.UnsupportedPlatform;
    return posix.tcgetattr(descriptor);
}

pub fn setAttributes(
    descriptor: fd.Descriptor,
    action: AttributeAction,
    attributes: Attributes,
) AttributeApplyError!void {
    if (!supportsPosixTerminalIo()) return error.UnsupportedPlatform;
    return posix.tcsetattr(descriptor, action, attributes);
}

pub fn setReadTiming(
    attributes: *Attributes,
    minimum_bytes: u8,
    timeout_deciseconds: u8,
) void {
    attributes.cc[@backingInt(posix.V.MIN)] = minimum_bytes;
    attributes.cc[@backingInt(posix.V.TIME)] = timeout_deciseconds;
}

pub const KeyboardInterruptError = error{
    UnsupportedPlatform,
    QueryFailed,
    ApplyFailed,
};

pub fn enableKeyboardInterrupt(descriptor: fd.Descriptor) KeyboardInterruptError!void {
    if (!supportsPosixTerminalIo()) return error.UnsupportedPlatform;

    var raw = posix.tcgetattr(descriptor) catch return error.QueryFailed;
    raw.lflag.ISIG = true;
    posix.tcsetattr(descriptor, .FLUSH, raw) catch return error.ApplyFailed;
}

pub fn columnsFromEnvironment() ?usize {
    if (!supportsPosixTerminalEnvironment()) return null;
    const text = env.getConstant("COLUMNS") orelse return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

pub fn capabilityEnvironmentValue(comptime key: []const u8) ?[]const u8 {
    if (!supportsPosixTerminalEnvironment()) return null;
    return env.getConstant(key);
}

fn supportsPosixTerminalIo() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi => false,
        else => true,
    };
}

fn supportsPosixTerminalEnvironment() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi => false,
        else => true,
    };
}
