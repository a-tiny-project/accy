const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.noLibc(&.{.standard_streams});

pub const File = std.Io.File;

pub fn debugIo() std.Io {
    return std.Options.debug_io;
}

pub fn stdin() File {
    return File.stdin();
}

pub fn stdout() File {
    return File.stdout();
}

pub fn stderr() File {
    return File.stderr();
}
