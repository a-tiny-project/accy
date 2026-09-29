const std = @import("std");
const composition = @import("../../root.zig");
const model = @import("../root.zig");
const serialization = @import("root.zig");

const source = composition.source;
const Reader = serialization.format.Reader;
const Writer = serialization.format.Writer;

pub fn write(writer: *Writer, value: model.CompositionVariant) serialization.SerializeError!void {
    try writer.writeInt(u64, value.id.value);
    try serialization.reference.writeAddress(writer, value.choice.target);
    try serialization.reference.writeAddress(writer, value.choice.policy);
    try writer.writeCount(value.fragments.len);
    for (value.fragments) |fragment_id| try writer.writeInt(u64, fragment_id.value);
    try writer.writeCount(value.call_sites.len);
    for (value.call_sites) |call_site| try serialization.call.write(writer, call_site);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *Reader,
    module: *model.CompositionModule,
) serialization.DeserializeError!void {
    const id = model.CompositionVariantId{ .value = try reader.readInt(u64) };
    const target = try serialization.reference.readAddress(reader);
    const policy = try serialization.reference.readAddress(reader);
    const fragment_count = try reader.readCount();
    const fragments = try allocator.alloc(source.FragmentId, fragment_count);
    defer allocator.free(fragments);
    for (fragments) |*fragment_id| fragment_id.* = .{ .value = try reader.readInt(u64) };

    const call_count = try reader.readCount();
    const call_specs = try allocator.alloc(model.CallSiteSpec, call_count);
    var calls_initialized: usize = 0;
    defer {
        var index = calls_initialized;
        while (index != 0) {
            index -= 1;
            serialization.call.deinitReadSpec(allocator, call_specs[index]);
        }
        allocator.free(call_specs);
    }
    for (call_specs) |*call_spec| {
        call_spec.* = try serialization.call.read(allocator, reader);
        calls_initialized += 1;
    }
    try module.addVariant(.{
        .id = id,
        .choice = .{ .target = target, .policy = policy },
        .fragments = fragments,
        .call_sites = call_specs,
    });
}
