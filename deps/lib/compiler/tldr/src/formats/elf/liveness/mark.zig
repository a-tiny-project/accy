const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const groups = @import("groups.zig");
const roots = @import("roots.zig");
const state = @import("state.zig");
const symbols = @import("symbols.zig");

const Allocator = std.mem.Allocator;
const model = root.model;

const GlobalSymbol = elf.layout.GlobalSymbol;
const ObjectFile = elf.parser.ObjectFile;

pub fn discardUnreachable(
    allocator: Allocator,
    objects: []ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!void {
    var live = try state.init(allocator, objects);
    defer state.deinit(&live, allocator);

    const entry = globals.get(options.entry_symbol) orelse return error.MissingEntrySymbol;

    var group_memberships = try elf.group.Index.init(allocator, objects);
    defer group_memberships.deinit(allocator);

    try roots.markReserved(objects, &live);
    try roots.markRetained(objects, &live);
    try symbols.mark(objects, globals, &live, entry.ref, options);

    var next: usize = 0;
    while (next < live.pending.items.len) : (next += 1) {
        const section_ref = live.pending.items[next];
        try groups.mark(objects, &group_memberships, &live, section_ref);
        try symbols.markRelocationTargets(objects, globals, &live, section_ref, options);
    }

    try state.discardUnmarked(&live, allocator, objects);
}
