const std = @import("std");
const artifact_root = @import("root.zig");
const bytecode = @import("../../bytecode/root.zig");

pub fn count(artifact: artifact_root.Artifact) usize {
    return artifact.payload.buffers.items.len + artifact.payload.text_dumps.items.len + artifact.payload.debug_records.items.len;
}

pub const Error = error{NoSpaceLeft};

pub fn write(
    artifact: artifact_root.Artifact,
    out: []bytecode.Resource,
) Error![]const bytecode.Resource {
    const required = count(artifact);
    if (out.len < required) return error.NoSpaceLeft;

    var index: usize = 0;
    for (artifact.payload.buffers.items) |buffer| {
        out[index] = .{
            .namespace = "choir.artifact.buffer",
            .name = buffer.name,
            .type_id = typeIdForBufferFormat(buffer.format),
            .data = buffer.bytes,
        };
        index += 1;
    }
    for (artifact.payload.text_dumps.items) |dump| {
        out[index] = .{
            .namespace = "choir.artifact.text-dump",
            .name = dump.name,
            .type_id = "choir.artifact.TextDump/v1",
            .data = dump.contents,
        };
        index += 1;
    }
    for (artifact.payload.debug_records.items) |record| {
        out[index] = .{
            .namespace = "choir.artifact.debug",
            .name = record.name,
            .type_id = typeIdForDebugRecord(record.kind),
            .data = record.bytes,
        };
        index += 1;
    }
    return out[0..index];
}

fn typeIdForBufferFormat(format: artifact_root.BufferFormat) []const u8 {
    return switch (format) {
        .raw => "choir.artifact.Buffer.raw/v1",
        .machine_code => "choir.artifact.Buffer.machine-code/v1",
        .object_file => "choir.artifact.Buffer.object-file/v1",
        .webassembly_module => "choir.artifact.Buffer.webassembly-module/v1",
        .assembly => "choir.artifact.Buffer.assembly/v1",
        .source_text => "choir.artifact.Buffer.source-text/v1",
        .debug_section => "choir.artifact.Buffer.debug-section/v1",
        .vendor => "choir.artifact.Buffer.vendor/v1",
    };
}

fn typeIdForDebugRecord(kind: artifact_root.DebugRecordKind) []const u8 {
    return switch (kind) {
        .line_table => "choir.artifact.DebugRecord.line-table/v1",
        .symbol_table => "choir.artifact.DebugRecord.symbol-table/v1",
        .dwarf_section => "choir.artifact.DebugRecord.dwarf-section/v1",
        .source_map => "choir.artifact.DebugRecord.source-map/v1",
        .note => "choir.artifact.DebugRecord.note/v1",
    };
}

test "artifact exposes payload bytecode resources" {
    var artifact = try artifact_root.Artifact.init(std.testing.allocator, .{ .kind = .container });
    defer artifact.deinit();

    try artifact.payload.addBuffer(.{
        .name = "kernel.o",
        .format = .object_file,
        .bytes = &.{ 0x7f, 'E', 'L', 'F' },
    });
    try artifact.payload.addTextDump(.{
        .name = "manifest",
        .contents = "target=x86_64",
    });
    try artifact.payload.addDebugRecord(.{
        .name = ".debug_line",
        .kind = .line_table,
        .bytes = &.{ 1, 2, 3 },
    });

    try std.testing.expectEqual(@as(usize, 3), count(artifact));
    const storage = try std.testing.allocator.alloc(bytecode.Resource, count(artifact));
    defer std.testing.allocator.free(storage);

    const resources = try write(artifact, storage);
    try std.testing.expectEqual(@as(usize, 3), resources.len);

    try std.testing.expectEqualStrings("choir.artifact.buffer", resources[0].namespace);
    try std.testing.expectEqualStrings("kernel.o", resources[0].name);
    try std.testing.expectEqualStrings("choir.artifact.Buffer.object-file/v1", resources[0].type_id);
    try std.testing.expectEqualSlices(u8, &.{ 0x7f, 'E', 'L', 'F' }, resources[0].data);

    try std.testing.expectEqualStrings("choir.artifact.text-dump", resources[1].namespace);
    try std.testing.expectEqualStrings("manifest", resources[1].name);
    try std.testing.expectEqualStrings("choir.artifact.TextDump/v1", resources[1].type_id);
    try std.testing.expectEqualStrings("target=x86_64", resources[1].data);

    try std.testing.expectEqualStrings("choir.artifact.debug", resources[2].namespace);
    try std.testing.expectEqualStrings(".debug_line", resources[2].name);
    try std.testing.expectEqualStrings("choir.artifact.DebugRecord.line-table/v1", resources[2].type_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, resources[2].data);

    try std.testing.expectError(error.NoSpaceLeft, write(artifact, storage[0..2]));
}

test "artifact bytecode resources round-trip with a module" {
    const ir = @import("../../core/root.zig");
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var artifact = try artifact_root.Artifact.init(std.testing.allocator, .{ .kind = .container });
    defer artifact.deinit();
    try artifact.payload.addBuffer(.{
        .name = "kernel.ptx",
        .format = .source_text,
        .bytes = ".version 6.0\n",
    });
    try artifact.payload.addTextDump(.{
        .name = "manifest",
        .contents = "target=nvptx",
    });

    const resource_storage = try std.testing.allocator.alloc(bytecode.Resource, count(artifact));
    defer std.testing.allocator.free(resource_storage);
    const resources = try write(artifact, resource_storage);

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    const bytes = try bytecode.encodeModuleWithResources(std.testing.allocator, module_op.op, resources);
    defer std.testing.allocator.free(bytes);

    const header = try bytecode.inspectHeader(bytes);
    try std.testing.expectEqual(bytecode.format_version, header.version);
    try std.testing.expect(header.compatibility().readable());

    var decode_ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(std.testing.allocator);
    try test_dialect.registerTestDialect(&decode_ctx);

    var decoded = try bytecode.decodeModule(std.testing.allocator, &decode_ctx, bytes);
    defer decoded.deinit();

    try std.testing.expect(decoded.format().readable());
    try std.testing.expectEqualStrings("test.module", decoded.module.name.name);
    try std.testing.expectEqual(resources.len, decoded.resources.len);
    for (resources, decoded.resources) |expected, actual| {
        try std.testing.expectEqualStrings(expected.namespace, actual.namespace);
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqualStrings(expected.type_id, actual.type_id);
        try std.testing.expectEqualSlices(u8, expected.data, actual.data);
    }
}
