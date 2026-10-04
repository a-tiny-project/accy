//! Validates a whole machine-code artifact before a runtime maps any of it.

const std = @import("std");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const machine = backends.machine_code;
const staging = @import("image.zig");

/// One machine-code function and its data buffers, read from an artifact that `Target` executes.
/// `init` checks every field the runtime relies on, so a view that exists links without
/// consulting the artifact again.
pub fn View(comptime Target: type) type {
    return struct {
        export_name: []const u8,
        code: []const u8,
        signature: artifact.Signature,
        data: machine.DataSymbolSet = .{},
        calls: std.ArrayListUnmanaged(machine.CallRelocation) = .empty,
        data_relocations: std.ArrayListUnmanaged(machine.DataRelocation) = .empty,

        const Self = @This();

        pub const Error = std.mem.Allocator.Error || error{InvalidArtifact};

        /// Fails with `error.InvalidArtifact` when the artifact is not machine code for `Target`,
        /// its buffers and provided symbols disagree, its function symbol lacks a signature
        /// `Target` passes and returns, or a relocation names no buffer, leaves its window, or
        /// overlaps another. A target that does not admit serialized code refuses before this
        /// load allocates, reserves a module, or examines artifact metadata.
        pub fn init(allocator: std.mem.Allocator, serialized: *const artifact.Artifact) Error!Self {
            if (!Target.allowsSerializedArtifact) return error.InvalidArtifact;
            try checkMetadata(serialized.metadata);
            const buffers = serialized.payload.buffers.items;
            const provided = serialized.linkage.provided_symbols.items;
            if (buffers.len == 0 or provided.len != buffers.len) return error.InvalidArtifact;
            const code = buffers[0];
            if (code.format != .machine_code or code.bytes.len == 0) return error.InvalidArtifact;
            const export_symbol = provided[0];
            if (export_symbol.kind != .function) return error.InvalidArtifact;
            if (export_symbol.binding != .external) return error.InvalidArtifact;
            if (export_symbol.name.len == 0) return error.InvalidArtifact;
            if (!std.mem.eql(u8, export_symbol.name, code.name)) return error.InvalidArtifact;
            const signature = export_symbol.signature orelse return error.InvalidArtifact;
            if (!Target.admitsSignature(&signature)) return error.InvalidArtifact;

            var view = Self{
                .export_name = export_symbol.name,
                .code = code.bytes,
                .signature = signature,
            };
            errdefer view.deinit(allocator);
            for (1..buffers.len) |index| try view.addData(allocator, serialized, index);

            const relocations = serialized.linkage.relocations.items;
            const offsets = try allocator.alloc(usize, relocations.len);
            defer allocator.free(offsets);
            for (relocations, offsets) |relocation, *offset| {
                offset.* = try view.addRelocation(allocator, relocation);
            }
            std.mem.sortUnstable(usize, offsets, {}, std.sort.asc(usize));
            if (offsets.len > 1) {
                for (offsets[0 .. offsets.len - 1], offsets[1..]) |previous, next| {
                    if (next - previous < Target.relocation_bytes) return error.InvalidArtifact;
                }
            }
            std.debug.assert(view.data.items().len + 1 == buffers.len);
            std.debug.assert(view.calls.items.len + view.data_relocations.items.len == relocations.len);
            return view;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
            self.calls.deinit(allocator);
            self.data_relocations.deinit(allocator);
            self.* = undefined;
        }

        pub fn image(self: *const Self) staging.Image {
            return .{
                .code = self.code,
                .calls = self.calls.items,
                .data = &self.data,
                .data_relocations = self.data_relocations.items,
            };
        }

        /// Requires machine code for `Target.architecture` and every ABI field `Target.abi` states.
        fn checkMetadata(metadata: artifact.Metadata) error{InvalidArtifact}!void {
            if (metadata.kind != .machine_code) return error.InvalidArtifact;
            if (metadata.target.architecture != Target.architecture) return error.InvalidArtifact;
            const expected = Target.abi;
            if (expected.pointer_width_bits) |bits| {
                if (metadata.abi.pointer_width_bits != bits) return error.InvalidArtifact;
            }
            if (expected.endianness) |endianness| {
                if (metadata.abi.endianness != endianness) return error.InvalidArtifact;
            }
            try requireText(expected.name, metadata.abi.name);
            try requireText(expected.calling_convention, metadata.abi.calling_convention);
            try requireText(expected.object_format, metadata.abi.object_format);
        }

        fn requireText(expected: ?[]const u8, actual: ?[]const u8) error{InvalidArtifact}!void {
            const want = expected orelse return;
            const have = actual orelse return error.InvalidArtifact;
            if (!std.mem.eql(u8, want, have)) return error.InvalidArtifact;
        }

        /// Adds the raw buffer at `index` as a data symbol under the name its provided symbol gives.
        fn addData(
            self: *Self,
            allocator: std.mem.Allocator,
            serialized: *const artifact.Artifact,
            index: usize,
        ) Error!void {
            std.debug.assert(index != 0);
            std.debug.assert(index < serialized.linkage.provided_symbols.items.len);
            const buffer = serialized.payload.buffers.items[index];
            const symbol = serialized.linkage.provided_symbols.items[index];
            if (buffer.format != .raw or symbol.kind != .data) return error.InvalidArtifact;
            if (!std.mem.eql(u8, buffer.name, symbol.name)) return error.InvalidArtifact;
            if (std.mem.eql(u8, buffer.name, self.export_name)) return error.InvalidArtifact;
            const binding: machine.DataSymbolBinding = switch (symbol.binding) {
                .local => .local,
                .external => .global,
                .weak => return error.InvalidArtifact,
            };
            const count = self.data.items().len;
            self.data.put(allocator, .{
                .name = buffer.name,
                .bytes = buffer.bytes,
                .alignment = buffer.alignment,
                .binding = binding,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidDataSymbol, error.ConflictingDataSymbol => return error.InvalidArtifact,
            };
            if (self.data.items().len == count) return error.InvalidArtifact;
            std.debug.assert(self.data.indexOf(buffer.name) == count);
        }

        /// Records one call or data relocation and returns its code offset.
        fn addRelocation(
            self: *Self,
            allocator: std.mem.Allocator,
            relocation: artifact.Relocation,
        ) Error!usize {
            const width = Target.relocation_bytes;
            const offset = std.math.cast(usize, relocation.offset) orelse return error.InvalidArtifact;
            if (offset > self.code.len or self.code.len - offset < width) return error.InvalidArtifact;
            if (relocation.width_bits) |bits| if (bits != width * 8) return error.InvalidArtifact;
            switch (relocation.kind) {
                .call => {
                    if (relocation.symbol.len == 0) return error.InvalidArtifact;
                    if (relocation.addend != 0) return error.InvalidArtifact;
                    try self.calls.append(allocator, .{ .offset = offset, .target = relocation.symbol });
                },
                .absolute => {
                    if (self.data.indexOf(relocation.symbol) == null) return error.InvalidArtifact;
                    try self.data_relocations.append(allocator, .{
                        .offset = offset,
                        .target = relocation.symbol,
                        .addend = relocation.addend,
                        .width_bits = width * 8,
                    });
                },
                else => return error.InvalidArtifact,
            }
            std.debug.assert(offset + width <= self.code.len);
            return offset;
        }
    };
}
