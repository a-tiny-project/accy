//! Highway's crypto operations: AES rounds with x86 AES-NI semantics and
//! carryless multiplication, each lowered to the instructions of the compile
//! target where it has them.

const lowering = @import("lowering.zig");

pub const Family = lowering.Family;
pub const Lowering = lowering.Lowering;
pub const loweringFor = lowering.loweringFor;

/// The AES operations: this build's lowering, each lowering it covers, and
/// the entry points.
pub const aes = @import("aes.zig");
/// Carryless multiplication: this build's lowering, each lowering it covers,
/// and the entry points.
pub const clmul = @import("clmul.zig");

pub const aesRound = aes.aesRound;
pub const aesLastRound = aes.aesLastRound;
pub const aesRoundInv = aes.aesRoundInv;
pub const aesLastRoundInv = aes.aesLastRoundInv;
pub const aesInvMixColumns = aes.aesInvMixColumns;
pub const aesKeyGenAssist = aes.aesKeyGenAssist;

pub const clMulLower = clmul.clMulLower;
pub const clMulUpper = clmul.clMulUpper;
