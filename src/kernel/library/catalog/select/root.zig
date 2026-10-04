const std = @import("std");

const descriptor_mod = @import("../root.zig");
const query_mod = descriptor_mod;

const owned = @import("owned.zig");
const static = @import("static/root.zig");

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const Query = query_mod.Query;

pub fn select(query: Query) ?Descriptor {
    return static.select(query);
}

pub fn selectOwned(backing_allocator: std.mem.Allocator, query: Query) !?OwnedDescriptor {
    return owned.selectOwned(backing_allocator, query);
}
