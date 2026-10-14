const fixture = @import("../fixture/root.zig");
const std = @import("std");
const alloc_arena = @import("alloc_arena");
const pretty = @import("pretty");
const choir = @import("../../root.zig");
const composition = @import("../root.zig");

const Allocator = std.mem.Allocator;
const Artifact = choir.backends.artifact.Artifact;
const CompositionModule = composition.CompositionModule;
const ProductKey = choir.product.ProductKey;
const Report = pretty.diagnostic.Report;

pub fn renderPathAlloc(
    allocator: Allocator,
    module: *const CompositionModule,
    variant_id: composition.CompositionVariantId,
    call_site_id: composition.CallSiteId,
) ![]u8 {
    try module.verify();
    const path = try module.diagnosticPath(variant_id, call_site_id);
    const caller = module.fragment(path.call_site.caller).?;
    const caller_export = caller.exportByName(path.call_site.caller_export).?;
    const runtime_import = caller.importByName(path.call_site.runtime_import).?;

    var arena_state = alloc_arena.Arena.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const title = try std.fmt.allocPrint(arena, "composition path: {s}", .{path.call_site.name});
    var report = try Report.init(arena, title);
    defer report.deinit();

    try report.section("source");
    try appendLocation(&report, path.source.*);
    try report.line("operation {s}", .{path.source.symbol});
    try report.line("module {s}", .{module.source_module.name});

    try report.section("variant");
    try report.line("[{d}]", .{path.variant.id.value});
    try appendAddress(&report, "target", path.variant.choice.target);
    try appendAddress(&report, "policy", path.variant.choice.policy);

    try report.section("partition");
    try report.line("[{d}] {s}", .{ path.partition.id.value, path.partition.name });
    try appendAddress(&report, "semantic product", path.partition.product);
    try report.line("effect {s}", .{@tagName(path.partition.effect)});
    for (path.partition.inputs) |id| try appendBoundary(&report, arena, module, "input", id);
    for (path.partition.outputs) |id| try appendBoundary(&report, arena, module, "output", id);

    try report.section("pipeline");
    try appendProduct(&report, "pipeline input", path.pipeline_input);
    try report.line("pipeline {s}", .{@tagName(path.fragment.pipeline)});

    try report.section("fragment");
    try report.line("[{d}] {s}", .{ path.fragment.id.value, @tagName(path.fragment.pipeline) });
    try appendExport(&report, path.fragment_export.*);
    for (path.fragment.exports) |*export_value| {
        if (export_value != path.fragment_export) try appendExport(&report, export_value.*);
    }
    for (path.fragment.imports) |import_value| try appendImport(&report, import_value);

    try report.section("call site");
    try report.line("[{d}] {s}", .{ path.call_site.id.value, path.call_site.name });
    try report.line(
        "route [{d}].{s} -> {s} -> [{d}].{s} (ABI v{d})",
        .{
            path.call_site.caller.value,
            path.call_site.caller_export,
            path.call_site.runtime_import,
            path.call_site.callee.value,
            path.call_site.callee_export,
            path.call_site.abi_version,
        },
    );
    try report.line("caller export {s} -> {s}", .{ caller_export.name, caller_export.symbol });
    try appendImport(&report, runtime_import.*);
    for (path.call_site.inputs) |id| try appendBoundary(&report, arena, module, "input", id);
    for (path.call_site.outputs) |id| try appendBoundary(&report, arena, module, "output", id);

    try report.section("artifact");
    try appendArtifact(&report, path.artifact);

    const rendered = try report.renderAlloc(.{ .width = 100 });
    return try allocator.dupe(u8, rendered);
}

fn appendLocation(report: *Report, provenance: composition.Provenance) !void {
    if (provenance.line == 0) {
        try report.line("{s}", .{provenance.path});
    } else if (provenance.column == 0) {
        try report.line("{s}:{d}", .{ provenance.path, provenance.line });
    } else {
        try report.line("{s}:{d}:{d}", .{ provenance.path, provenance.line, provenance.column });
    }
}

fn appendAddress(report: *Report, label: []const u8, address: choir.product.ProductRef) !void {
    try report.line("{s} {s}/{s}/{s} [{s}]", .{
        label, address.producer, address.source, address.stage, address.variant,
    });
}

fn appendProduct(report: *Report, label: []const u8, key: ProductKey) !void {
    try appendAddress(report, label, key.ref);
    try report.line("content bucket 0x{x:0>16}; exact record {d} bytes", .{
        key.fingerprint(), key.record.bytes().len,
    });
}

fn appendBoundary(
    report: *Report,
    arena: Allocator,
    module: *const CompositionModule,
    role: []const u8,
    id: composition.BoundaryId,
) !void {
    const boundary = module.source_module.boundary(id).?;
    const shape = try shapeAlloc(arena, boundary);
    try report.line(
        "{s} [{d}] {s}: {s}, {d} bytes, {s}, {s}",
        .{
            role,
            boundary.id.value,
            boundary.name,
            shape,
            boundary.byte_size,
            @tagName(boundary.access),
            @tagName(boundary.ownership),
        },
    );
    switch (boundary.alias) {
        .disjoint => try report.line("{s} alias disjoint", .{role}),
        .boundary => |alias| try report.line("{s} aliases boundary [{d}]", .{ role, alias.value }),
    }
    try appendNamedLocation(report, role, boundary.provenance);
}

fn appendNamedLocation(report: *Report, label: []const u8, provenance: composition.Provenance) !void {
    if (provenance.line == 0) {
        try report.line("{s} source {s}", .{ label, provenance.path });
    } else if (provenance.column == 0) {
        try report.line("{s} source {s}:{d}", .{ label, provenance.path, provenance.line });
    } else {
        try report.line("{s} source {s}:{d}:{d}", .{ label, provenance.path, provenance.line, provenance.column });
    }
}

fn shapeAlloc(allocator: Allocator, boundary: *const composition.Boundary) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.print("{s}", .{@tagName(boundary.element_type)});
    for (boundary.dimensions) |dimension| try output.writer.print("[{d}]", .{dimension});
    return try output.toOwnedSlice();
}

fn appendExport(report: *Report, export_value: composition.Export) !void {
    try report.line(
        "export {s} -> {s} (ABI v{d})",
        .{ export_value.name, export_value.symbol, export_value.abi_version },
    );
}

fn appendImport(report: *Report, import_value: composition.Import) !void {
    try report.line(
        "{s} import {s} -> {s} (ABI v{d})",
        .{ @tagName(import_value.kind), import_value.name, import_value.symbol, import_value.abi_version },
    );
}

fn appendArtifact(report: *Report, artifact: *const Artifact) !void {
    try report.line("{s}", .{@tagName(artifact.metadata.kind)});
    try report.line(
        "resources {d}, buffers {d}, relocations {d}",
        .{ choir.backends.artifact.resource.count(artifact.*), artifact.payload.buffers.items.len, artifact.linkage.relocations.items.len },
    );
    const target = artifact.metadata.target;
    try report.line("target {s}", .{@tagName(target.architecture)});
    if (target.triple) |value| try report.line("triple {s}", .{value});
    if (target.vendor) |value| try report.line("vendor {s}", .{value});
    if (target.os) |value| try report.line("operating system {s}", .{value});
    if (target.environment) |value| try report.line("environment {s}", .{value});
    if (target.cpu) |value| try report.line("CPU {s}", .{value});
    for (target.features) |feature| try report.line("feature {s}", .{feature});
    const artifact_abi = artifact.metadata.abi;
    if (artifact_abi.name) |value| try report.line("ABI {s}", .{value});
    if (artifact_abi.calling_convention) |value| try report.line("calling convention {s}", .{value});
    if (artifact_abi.object_format) |value| try report.line("object format {s}", .{value});
    if (artifact_abi.pointer_width_bits) |value| try report.line("pointer width {d} bits", .{value});
    if (artifact_abi.endianness) |value| try report.line("endianness {s}", .{@tagName(value)});
    for (artifact.linkage.provided_symbols.items) |symbol| {
        try report.line("provides {s} ({s}, {s})", .{ symbol.name, @tagName(symbol.kind), @tagName(symbol.binding) });
    }
    for (artifact.linkage.required_symbols.items) |symbol| {
        try report.line("requires {s} ({s}, {s})", .{ symbol.name, @tagName(symbol.kind), @tagName(symbol.binding) });
    }
}
