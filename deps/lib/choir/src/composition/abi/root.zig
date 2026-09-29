//! Fixed-width C-compatible ABI between independently compiled fragments.
//! Frames expose no Zig slices, allocators, errors, or IR pointers. Resources are scoped to one
//! loaded composition and one invocation, and incompatible versions fail before payload access.

pub const contract = @import("contract.zig");
pub const context = @import("context.zig");
pub const frame = @import("frame.zig");

pub const version = contract.version;
pub const invoke_symbol = contract.invoke_symbol;
pub const max_resources = contract.max_resources;
pub const Status = contract.Status;
pub const Access = contract.Access;
pub const decodeStatus = contract.decodeStatus;
pub const decodeAccess = contract.decodeAccess;
pub const Context = context.Context;
pub const Resource = frame.Resource;
pub const Frame = frame.Frame;
pub const StatusOrResources = frame.StatusOrResources;
pub const StatusOrBytes = frame.StatusOrBytes;

pub const InvokeFn = *const fn (?*Context, u64, ?*Frame) callconv(.c) i64;
