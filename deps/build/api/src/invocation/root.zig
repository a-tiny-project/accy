//! The validated build invocation supplied by the shared compiler launcher.

pub const record = @import("record.zig");
pub const arguments = @import("arguments.zig");
pub const environment = @import("environment.zig");
pub const Record = record.Record;
pub const Maker = record.Maker;
pub const Binding = record.Binding;
pub const maximum_bytes = record.maximum_bytes;
pub const variable = record.variable;
pub const refresh = record.refresh;
pub const receive = record.receive;
pub const forget = record.forget;
pub const configuration = @import("configuration.zig");
