const model = @import("model.zig");

pub const Encoded = model.Encoded;
pub const GPR = model.GPR;
pub const SP = model.SP;
pub const ZR = model.ZR;
pub const FPR = model.FPR;
pub const GPRSize = model.GPRSize;
pub const FPRSize = model.FPRSize;
pub const Register = model.Register;
pub const allocatable_gprs = model.allocatable_gprs;
pub const callee_saved_gprs = model.callee_saved_gprs;
pub const allocatable_fprs = model.allocatable_fprs;
pub const callee_saved_fprs = model.callee_saved_fprs;
