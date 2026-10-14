const lifecycle = @import("lifecycle.zig");
const mapping = @import("mapping.zig");
const model = @import("model.zig");

pub const magic = model.magic;
pub const FreeNode = model.FreeNode;
pub const Page = model.Page;

pub const createFromBacking = mapping.createFromBacking;
pub const createFromOs = mapping.createFromOs;
pub const destroyFromOs = mapping.destroyFromOs;
pub const destroyInBacking = mapping.destroyInBacking;
pub const discardUnused = lifecycle.discardUnused;
pub const fromBlock = mapping.fromBlock;
pub const restoreDiscarded = lifecycle.restoreDiscarded;
