pub const contract = @import("contract.zig");
pub const fragment = @import("fragment.zig");
pub const call = @import("call.zig");
pub const variant = @import("variant.zig");
pub const module = @import("module.zig");

pub const Error = contract.Error;
pub const verifyFragmentSpec = fragment.verifySpec;
pub const verifyCallSiteSpec = call.verifySpec;
pub const verifyCompositionVariantSpec = variant.verifySpec;
pub const verifyModule = module.verify;
