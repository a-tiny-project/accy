const std = @import("std");
const ir = @import("../core/root.zig");
const artifact_mod = @import("root.zig").artifact;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    DuplicateTranslation,
    InvalidTranslation,
    UnknownTranslation,
};

pub const Request = struct {
    module: *ir.Operation,
    entry: ?[]const u8 = null,
};

pub const EmitBytesFn = *const fn (Allocator, Request) anyerror![]u8;

pub const Descriptor = struct {
    name: []const u8,
    target_dialect_name: []const u8,
    format_name: []const u8,
    artifact_kind: artifact_mod.ArtifactKind = .unknown,
    buffer_format: artifact_mod.BufferFormat = .vendor,
};

pub const Registration = struct {
    name: []const u8,
    target_dialect_name: []const u8,
    format_name: []const u8,
    artifact_kind: artifact_mod.ArtifactKind = .unknown,
    buffer_format: artifact_mod.BufferFormat = .vendor,
    emit_bytes: EmitBytesFn,
};

pub fn registration(comptime Impl: type, descriptor: Descriptor) Registration {
    comptime {
        if (!@hasDecl(Impl, "emitBytes")) @compileError("backend translation missing emitBytes");
        const emit_bytes: EmitBytesFn = Impl.emitBytes;
        _ = emit_bytes;
    }

    return .{
        .name = descriptor.name,
        .target_dialect_name = descriptor.target_dialect_name,
        .format_name = descriptor.format_name,
        .artifact_kind = descriptor.artifact_kind,
        .buffer_format = descriptor.buffer_format,
        .emit_bytes = Impl.emitBytes,
    };
}

pub const Registry = struct {
    allocator: Allocator,
    registrations: std.ArrayListUnmanaged(Registration) = .empty,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.registrations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, item: Registration) Error!void {
        try validate(item);
        if (self.lookup(item.name) != null) return error.DuplicateTranslation;
        if (self.lookupTargetFormat(item.target_dialect_name, item.format_name) != null) return error.DuplicateTranslation;
        try self.registrations.ensureTotalCapacity(self.allocator, self.registrations.items.len + 1);
        self.registrations.appendAssumeCapacity(item);
    }

    pub fn registerAll(self: *Registry, items: []const Registration) Error!void {
        for (items) |item| {
            try self.register(item);
        }
    }

    pub fn lookup(self: *const Registry, name: []const u8) ?Registration {
        for (self.registrations.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }
        return null;
    }

    pub fn lookupTargetFormat(self: *const Registry, target_dialect_name: []const u8, format_name: []const u8) ?Registration {
        for (self.registrations.items) |item| {
            if (std.mem.eql(u8, item.target_dialect_name, target_dialect_name) and
                std.mem.eql(u8, item.format_name, format_name))
            {
                return item;
            }
        }
        return null;
    }

    pub fn emitBytes(
        self: *const Registry,
        result_allocator: Allocator,
        target_dialect_name: []const u8,
        format_name: []const u8,
        request: Request,
    ) anyerror![]u8 {
        const item = self.lookupTargetFormat(target_dialect_name, format_name) orelse return error.UnknownTranslation;
        return item.emit_bytes(result_allocator, request);
    }

    pub fn emitArtifact(
        self: *const Registry,
        result_allocator: Allocator,
        target_dialect_name: []const u8,
        format_name: []const u8,
        request: Request,
    ) anyerror!artifact_mod.Artifact {
        const item = self.lookupTargetFormat(target_dialect_name, format_name) orelse return error.UnknownTranslation;
        const bytes = try item.emit_bytes(result_allocator, request);
        defer result_allocator.free(bytes);

        var artifact = try artifact_mod.Artifact.init(result_allocator, .{
            .kind = item.artifact_kind,
            .producer = item.name,
        });
        errdefer artifact.deinit();

        try artifact.payload.addBuffer(.{
            .name = item.format_name,
            .format = item.buffer_format,
            .bytes = bytes,
        });
        return artifact;
    }
};

fn validate(item: Registration) Error!void {
    if (item.name.len == 0) return error.InvalidTranslation;
    if (item.target_dialect_name.len == 0) return error.InvalidTranslation;
    if (item.format_name.len == 0) return error.InvalidTranslation;
}

const FakeTranslation = struct {
    pub fn emitBytes(result_allocator: Allocator, request: Request) anyerror![]u8 {
        _ = request;
        return result_allocator.dupe(u8, "fake-bytes");
    }
};

const fake_registration = registration(FakeTranslation, .{
    .name = "fake.binary",
    .target_dialect_name = "fake",
    .format_name = "fake-binary",
});

test "backend translation registry dispatches by target dialect and format" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(fake_registration);
    try std.testing.expect(registry.lookup("fake.binary") != null);
    try std.testing.expect(registry.lookupTargetFormat("fake", "fake-binary") != null);
    try std.testing.expect(registry.lookupTargetFormat("fake", "missing") == null);

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("fake.op", .unknown));

    const bytes = try registry.emitBytes(std.testing.allocator, "fake", "fake-binary", .{ .module = op });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("fake-bytes", bytes);
}

test "backend translation registry rejects duplicate registrations" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(fake_registration);
    try std.testing.expectError(error.DuplicateTranslation, registry.register(fake_registration));

    const duplicate_target = registration(FakeTranslation, .{
        .name = "fake.second",
        .target_dialect_name = "fake",
        .format_name = "fake-binary",
    });
    try std.testing.expectError(error.DuplicateTranslation, registry.register(duplicate_target));
}

test "backend translation registry emits artifacts" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const artifact_registration = registration(FakeTranslation, .{
        .name = "fake.artifact",
        .target_dialect_name = "fake",
        .format_name = "fake-object",
        .artifact_kind = .object_file,
        .buffer_format = .object_file,
    });
    try registry.register(artifact_registration);

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("fake.op", .unknown));

    var artifact = try registry.emitArtifact(std.testing.allocator, "fake", "fake-object", .{ .module = op });
    defer artifact.deinit();

    try std.testing.expectEqual(artifact_mod.ArtifactKind.object_file, artifact.metadata.kind);
    try std.testing.expectEqual(@as(usize, 1), artifact.payload.buffers.items.len);
    try std.testing.expectEqualStrings("fake-object", artifact.payload.buffers.items[0].name);
    try std.testing.expectEqualStrings("fake-bytes", artifact.payload.buffers.items[0].bytes);
}

test "backend translation registry reports unknown targets" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("fake.op", .unknown));
    try std.testing.expectError(
        error.UnknownTranslation,
        registry.emitBytes(std.testing.allocator, "missing", "fake-binary", .{ .module = op }),
    );
}
