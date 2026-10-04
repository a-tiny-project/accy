const registry = @import("registry.zig");

pub const builtin = @import("builtin.zig");
pub const arith = @import("arith/root.zig");
pub const memref = @import("memref.zig");
pub const rc = @import("rc.zig");
pub const scf = @import("scf.zig");
pub const func = @import("func.zig");
pub const tile = @import("tile.zig");
pub const aarch64 = @import("aarch64.zig");
pub const gpu = @import("gpu/root.zig");

pub const BuiltinDialect = builtin.BuiltinDialect;
pub const ArithDialect = arith.ArithDialect;
pub const MemrefDialect = memref.MemrefDialect;
pub const RcDialect = rc.RcDialect;
pub const ScfDialect = scf.ScfDialect;
pub const FuncDialect = func.FuncDialect;
pub const TileDialect = tile.TileDialect;
pub const AddressSpace = memref.AddressSpace;
pub const AtomicRmwKind = memref.AtomicRmwKind;
pub const FenceScope = memref.FenceScope;
pub const FenceOrdering = memref.FenceOrdering;
pub const AArch64Dialect = aarch64.AArch64Dialect;

pub const TileMemLevel = tile.TileMemLevel;

pub const choir_registry = registry.choir_registry;
pub const registerChoirDialect = registry.registerChoirDialect;
pub const registerAllDialects = registry.registerAllDialects;
