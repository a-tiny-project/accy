pub const coff = @import("coff.zig");
pub const dispatch = @import("dispatch.zig");
pub const elf = @import("elf/root.zig");
pub const macho = @import("macho.zig");

pub const parseObject = dispatch.parseObject;
pub const detectObjectFormat = dispatch.detectObjectFormat;
pub const validateInputFormats = dispatch.validateInputFormats;
