const std = @import("std");
const options_mod = @import("options.zig");
const pass_mod = @import("pass/root.zig");

pub const PipelineError = error{
    DuplicatePipeline,
    UnknownPipeline,
};

pub const RegistryError = PipelineError || error{
    DuplicatePass,
    UnknownPass,
};

pub const PassOptionSpec = options_mod.PassOptionSpec;
pub const PassOptionChoice = options_mod.PassOptionChoice;
pub const PassOptionAssignment = options_mod.PassOptionAssignment;
pub const PassOptionSet = options_mod.PassOptionSet;
pub const PassOptionsBuilderFn = *const fn (std.mem.Allocator, PassOptionSet) anyerror!pass_mod.Pass;
pub const PipelineOptionsBuilderFn = *const fn (*pass_mod.OpPassManager, PassOptionSet) anyerror!void;

pub const PassRegistration = struct {
    name: []const u8,
    description: []const u8,
    pass: pass_mod.Pass,
    target_op_name: ?[]const u8 = null,
    options: []const PassOptionSpec = &.{},
    build_with_options: ?PassOptionsBuilderFn = null,

    pub fn addTo(self: PassRegistration, manager: *pass_mod.OpPassManager) anyerror!void {
        if (self.target_op_name) |target| {
            const nested = try manager.nest(target);
            try nested.addPass(self.pass);
        } else {
            try manager.addPass(self.pass);
        }
    }

    pub fn addToWithOptions(
        self: PassRegistration,
        manager: *pass_mod.OpPassManager,
        option_text: []const u8,
        option_set: PassOptionSet,
    ) anyerror!void {
        const build = self.build_with_options orelse return error.PassOptionsNotSupported;
        try options_mod.validatePassOptions(self.options, option_set);
        const target_manager = if (self.target_op_name) |target|
            try manager.nest(target)
        else
            manager;
        var pass = try build(manager.allocator, option_set);
        errdefer pass.deinit(manager.allocator);
        if (option_text.len != 0) {
            pass.textual_options = try manager.allocator.dupe(u8, option_text);
            pass.owns_textual_options = true;
        } else {
            pass.textual_options = "";
        }
        try target_manager.addPass(pass);
    }
};

pub const PipelineBuilderFn = *const fn (*pass_mod.OpPassManager) anyerror!void;

pub const PipelineRegistration = struct {
    name: []const u8,
    description: []const u8,
    build: PipelineBuilderFn,
    options: []const PassOptionSpec = &.{},
    build_with_options: ?PipelineOptionsBuilderFn = null,

    pub fn addTo(self: PipelineRegistration, manager: *pass_mod.OpPassManager) anyerror!void {
        try self.build(manager);
    }

    pub fn addToWithOptions(
        self: PipelineRegistration,
        manager: *pass_mod.OpPassManager,
        option_set: PassOptionSet,
    ) anyerror!void {
        const build = self.build_with_options orelse return error.PassOptionsNotSupported;
        try options_mod.validatePassOptions(self.options, option_set);
        try build(manager, option_set);
    }
};

pub const PassRegistry = struct {
    allocator: std.mem.Allocator,
    passes: std.ArrayListUnmanaged(PassRegistration) = .empty,
    pipelines: std.ArrayListUnmanaged(PipelineRegistration) = .empty,

    pub fn init(allocator: std.mem.Allocator) PassRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PassRegistry) void {
        self.passes.deinit(self.allocator);
        self.pipelines.deinit(self.allocator);
    }

    pub fn registerPass(
        self: *PassRegistry,
        registration: PassRegistration,
    ) (std.mem.Allocator.Error || RegistryError)!void {
        if (self.lookupPass(registration.name) != null) return error.DuplicatePass;
        if (self.lookupPipeline(registration.name) != null) return error.DuplicatePass;
        try self.passes.append(self.allocator, registration);
    }

    pub fn registerPipeline(
        self: *PassRegistry,
        registration: PipelineRegistration,
    ) (std.mem.Allocator.Error || RegistryError)!void {
        if (self.lookupPipeline(registration.name) != null) return error.DuplicatePipeline;
        if (self.lookupPass(registration.name) != null) return error.DuplicatePipeline;
        try self.pipelines.append(self.allocator, registration);
    }

    pub fn entryCount(self: *const PassRegistry) usize {
        return self.passes.items.len + self.pipelines.items.len;
    }

    pub fn lookupPass(self: *const PassRegistry, name: []const u8) ?PassRegistration {
        for (self.passes.items) |registration| {
            if (std.mem.eql(u8, registration.name, name)) return registration;
        }
        return null;
    }

    pub fn lookupPipeline(self: *const PassRegistry, name: []const u8) ?PipelineRegistration {
        for (self.pipelines.items) |registration| {
            if (std.mem.eql(u8, registration.name, name)) return registration;
        }
        return null;
    }

    pub fn addPassTo(
        self: *const PassRegistry,
        name: []const u8,
        manager: *pass_mod.PassManager,
    ) anyerror!void {
        const registration = self.lookupPass(name) orelse return error.UnknownPass;
        try registration.addTo(&manager.root);
    }

    pub fn addPipelineTo(
        self: *const PassRegistry,
        name: []const u8,
        manager: *pass_mod.PassManager,
    ) anyerror!void {
        const registration = self.lookupPipeline(name) orelse return error.UnknownPipeline;
        try registration.addTo(&manager.root);
    }

    pub fn writeHelp(self: *const PassRegistry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("passes:\n");
        if (self.passes.items.len == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            for (self.passes.items) |registration| {
                try writer.print("  {s} - {s}\n", .{ registration.name, registration.description });
                for (registration.options) |option| {
                    try writer.print("    {s} - {s}\n", .{ option.name, option.description });
                }
            }
        }

        try writer.writeAll("pipelines:\n");
        if (self.pipelines.items.len == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            for (self.pipelines.items) |registration| {
                try writer.print("  {s} - {s}\n", .{ registration.name, registration.description });
                for (registration.options) |option| {
                    try writer.print("    {s} - {s}\n", .{ option.name, option.description });
                }
            }
        }
    }

    pub fn formatHelpAlloc(self: *const PassRegistry, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try self.writeHelp(&out.writer);
        return try out.toOwnedSlice();
    }
};

pub const PipelineRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(PipelineRegistration) = .empty,

    pub fn init(allocator: std.mem.Allocator) PipelineRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PipelineRegistry) void {
        self.entries.deinit(self.allocator);
    }

    pub fn registerPipeline(
        self: *PipelineRegistry,
        registration: PipelineRegistration,
    ) (std.mem.Allocator.Error || PipelineError)!void {
        if (self.lookup(registration.name) != null) return error.DuplicatePipeline;
        try self.entries.append(self.allocator, registration);
    }

    pub fn lookup(self: *const PipelineRegistry, name: []const u8) ?PipelineRegistration {
        for (self.entries.items) |registration| {
            if (std.mem.eql(u8, registration.name, name)) return registration;
        }
        return null;
    }

    pub fn addPipelineTo(
        self: *const PipelineRegistry,
        name: []const u8,
        manager: *pass_mod.PassManager,
    ) anyerror!void {
        const registration = self.lookup(name) orelse return error.UnknownPipeline;
        try registration.addTo(&manager.root);
    }

    pub fn addPipelineToWithOptions(
        self: *const PipelineRegistry,
        name: []const u8,
        manager: *pass_mod.PassManager,
        option_set: PassOptionSet,
    ) anyerror!void {
        const registration = self.lookup(name) orelse return error.UnknownPipeline;
        try registration.addToWithOptions(&manager.root, option_set);
    }
};

fn noopPass(_: *pass_mod.PassContext) pass_mod.PassResult {
    return .success;
}

const test_pass = pass_mod.Pass{
    .name = "choir-pipeline-test-pass",
    .description = "test pass for pipeline registry",
    .run_fn = noopPass,
};

const test_pass_registration = PassRegistration{
    .name = "choir-test-pass",
    .description = "test pass registration",
    .pass = test_pass,
};

const test_nested_pass_registration = PassRegistration{
    .name = "choir-test-nested-pass",
    .description = "test nested pass registration",
    .pass = test_pass,
    .target_op_name = "test.nested",
};

fn buildTestPipeline(manager: *pass_mod.OpPassManager) anyerror!void {
    try manager.addPass(test_pass);
}

const test_pipeline = PipelineRegistration{
    .name = "choir-test-pipeline",
    .description = "test pipeline registration",
    .build = buildTestPipeline,
};

const test_pipeline_option_specs = [_]PassOptionSpec{
    .{
        .name = "limit",
        .description = "pipeline limit",
        .kind = .unsigned,
    },
};

fn buildTestPipelineWithOptions(manager: *pass_mod.OpPassManager, options: PassOptionSet) anyerror!void {
    _ = try options.unsignedValue(usize, "limit", 0);
    try manager.addPass(test_pass);
    try manager.addPass(test_pass);
}

const test_pipeline_with_options = PipelineRegistration{
    .name = "choir-test-pipeline-options",
    .description = "test pipeline registration with options",
    .build = buildTestPipeline,
    .options = &test_pipeline_option_specs,
    .build_with_options = buildTestPipelineWithOptions,
};

test "pipeline registry registers and applies named pipelines" {
    var registry = PipelineRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerPipeline(test_pipeline);
    try std.testing.expect(registry.lookup(test_pipeline.name) != null);
    try std.testing.expectError(error.DuplicatePipeline, registry.registerPipeline(test_pipeline));

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try registry.addPipelineTo(test_pipeline.name, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);
    try std.testing.expectError(error.UnknownPipeline, registry.addPipelineTo("missing", &manager));
}

test "pass registry registers selected passes and pipelines by name" {
    var registry = PassRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerPass(test_pass_registration);
    try registry.registerPipeline(test_pipeline);
    try std.testing.expect(registry.lookupPass(test_pass_registration.name) != null);
    try std.testing.expect(registry.lookupPipeline(test_pipeline.name) != null);
    try std.testing.expectError(error.DuplicatePass, registry.registerPass(test_pass_registration));
    try std.testing.expectError(error.DuplicatePipeline, registry.registerPipeline(test_pipeline));

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try registry.addPassTo(test_pass_registration.name, &manager);
    try registry.addPipelineTo(test_pipeline.name, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.root.pipeline.items.len);
    try std.testing.expectError(error.UnknownPass, registry.addPassTo("missing", &manager));
    try std.testing.expectError(error.UnknownPipeline, registry.addPipelineTo("missing", &manager));
}

test "pass registry keeps pass and pipeline names in one textual namespace" {
    var registry = PassRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerPass(test_pass_registration);
    try std.testing.expectError(
        error.DuplicatePipeline,
        registry.registerPipeline(.{
            .name = test_pass_registration.name,
            .description = "pipeline colliding with a pass name",
            .build = buildTestPipeline,
        }),
    );

    var other = PassRegistry.init(std.testing.allocator);
    defer other.deinit();

    try other.registerPipeline(test_pipeline);
    try std.testing.expectError(
        error.DuplicatePass,
        other.registerPass(.{
            .name = test_pipeline.name,
            .description = "pass colliding with a pipeline name",
            .pass = test_pass,
        }),
    );
}

test "pass registry writes inspectable pass and pipeline help" {
    var registry = PassRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerPass(test_pass_registration);
    try registry.registerPipeline(test_pipeline);
    try registry.registerPipeline(test_pipeline_with_options);
    try std.testing.expectEqual(@as(usize, 3), registry.entryCount());

    const text = try registry.formatHelpAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "passes:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_pass_registration.name) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_pass_registration.description) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pipelines:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_pipeline.name) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_pipeline.description) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_pipeline_option_specs[0].name) != null);
}

test "pass registry preserves target operation nesting" {
    var registry = PassRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerPass(test_nested_pass_registration);

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try registry.addPassTo(test_nested_pass_registration.name, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);

    switch (manager.root.pipeline.items[0]) {
        .nested => |nested| {
            try std.testing.expectEqualStrings("test.nested", nested.target_op_name.?);
            try std.testing.expectEqual(@as(usize, 1), nested.pipeline.items.len);
        },
        .pass => return error.TestExpectedNestedPassManager,
    }
}

test "pipeline registry validates and applies pipeline options" {
    var registry = PassRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerPipeline(test_pipeline);
    try registry.registerPipeline(test_pipeline_with_options);

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();

    const assignments = [_]PassOptionAssignment{
        .{ .name = "limit", .value = "2" },
    };
    try registry.lookupPipeline(test_pipeline_with_options.name).?.addToWithOptions(
        &manager.root,
        .{ .assignments = &assignments },
    );
    try std.testing.expectEqual(@as(usize, 2), manager.root.pipeline.items.len);

    try std.testing.expectError(
        error.UnknownPassOption,
        registry.lookupPipeline(test_pipeline_with_options.name).?.addToWithOptions(
            &manager.root,
            .{ .assignments = &.{.{ .name = "missing", .value = "1" }} },
        ),
    );
    try std.testing.expectError(
        error.PassOptionsNotSupported,
        registry.lookupPipeline(test_pipeline.name).?.addToWithOptions(
            &manager.root,
            .{ .assignments = &assignments },
        ),
    );
}
