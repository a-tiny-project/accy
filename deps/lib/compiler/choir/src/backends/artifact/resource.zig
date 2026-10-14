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
