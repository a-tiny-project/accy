pub const contract = @import("contract.zig");
pub const boundary = @import("boundary.zig");
pub const partition = @import("partition.zig");
pub const call = @import("call.zig");
pub const module = @import("module.zig");

pub const Error = contract.Error;
pub const verifyBoundarySpec = boundary.verifySpec;
pub const verifyPartitionSpec = partition.verifySpec;
pub const verifyCallSiteSpec = call.verifySpec;
pub const verifyModule = module.verify;
