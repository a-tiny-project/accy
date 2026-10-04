const std = @import("std");
const root = @import("../../root.zig");
const macho = @import("root.zig");

pub fn linkExecutable(
    allocator: std.mem.Allocator,
    inputs: []const root.Input,
    options: root.LinkOptions,
) root.Error!root.LinkedImage {
    var layout = try macho.layout.Layout.init(allocator, inputs, options);
    defer layout.deinit(allocator);
    const bytes = try allocator.alloc(u8, layout.requiredBytes());
    errdefer allocator.free(bytes);
    try layout.write(bytes);
    var manifest = try root.incremental.Builder.init(allocator, options);
    defer manifest.deinit();
    for (inputs) |input| try manifest.addInput(input);
    try manifest.addSection("__TEXT", options.image_base, 0, layout.text_segment_bytes, layout.text_segment_bytes, macho.layout.vm_page_bytes);
    try manifest.addSection("__DATA", try macho.layout.add(options.image_base, layout.data_offset), layout.data_offset, layout.data_segment_bytes, layout.data_segment_bytes, macho.layout.vm_page_bytes);
    try manifest.addSection("__LINKEDIT", try macho.layout.add(options.image_base, layout.linkedit_offset), layout.linkedit_offset, layout.counts.file - layout.linkedit_offset, layout.counts.file - layout.linkedit_offset, macho.layout.vm_page_bytes);
    return .{ .bytes = bytes, .manifest = try manifest.finish() };
}
