const std = @import("std");
const composition = @import("../root.zig");
const loaded = @import("root.zig");

const Allocator = std.mem.Allocator;
const abi = composition.abi;
const model = composition.module;
const source = composition.source;

pub const FragmentVTable = struct {
    invoke: ?*const fn (*anyopaque, *const model.CallSite, *abi.Context, *abi.Frame) abi.Status = null,
    lookup_export: ?*const fn (*anyopaque, []const u8) ?usize = null,
    deinit: *const fn (*anyopaque, Allocator) void,
};

pub const MaterializedFragment = struct {
    state: *anyopaque,
    vtable: *const FragmentVTable,
};

pub const FragmentMaterializer = struct {
    id: source.FragmentId,
    context: *anyopaque,
    materialize: *const fn (*anyopaque, Allocator, *const model.CompositionModule, *const model.Fragment) anyerror!MaterializedFragment,
};

pub const LoadedFragment = struct {
    id: source.FragmentId,
    state: *anyopaque,
    vtable: *const FragmentVTable,
};

pub fn deinitUnique(
    allocator: Allocator,
    fragments: []const LoadedFragment,
    observer: ?loaded.LifecycleObserver,
) void {
    var index = fragments.len;
    while (index != 0) {
        index -= 1;
        const fragment_value = fragments[index];
        var earlier_index: usize = 0;
        var aliased = false;
        while (earlier_index < index) : (earlier_index += 1) {
            if (fragments[earlier_index].state == fragment_value.state) {
                aliased = true;
                break;
            }
        }
        if (aliased) continue;
        fragment_value.vtable.deinit(fragment_value.state, allocator);
        if (observer) |value| value.record(.{ .fragment_destroyed = fragment_value.id });
    }
}
