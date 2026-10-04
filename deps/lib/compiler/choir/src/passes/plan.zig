const std = @import("std");
const pass_mod = @import("pass/root.zig");
const registry_mod = @import("pipeline.zig");

pub const Target = union(enum) {
    any,
    op: []const u8,
};

pub const Invocation = struct {
    name: []const u8,
    options: []const registry_mod.PassOptionAssignment = &.{},
    text: ?[]const u8 = null,

    pub fn named(name: []const u8) Invocation {
        return .{ .name = name };
    }

    pub fn configured(
        name: []const u8,
        options: []const registry_mod.PassOptionAssignment,
    ) Invocation {
        return .{
            .name = name,
            .options = options,
        };
    }

    pub fn textual(
        name: []const u8,
        text: []const u8,
        options: []const registry_mod.PassOptionAssignment,
    ) Invocation {
        return .{
            .name = name,
            .options = options,
            .text = text,
        };
    }

    fn hasOptions(self: Invocation) bool {
        return self.text != null or self.options.len != 0;
    }
};

pub const Nested = struct {
    target: Target,
    steps: []const Step,
};

pub const Step = union(enum) {
    pass: Invocation,
    pipeline: Invocation,
    nested: Nested,

    pub fn namedPass(name: []const u8) Step {
        return .{ .pass = Invocation.named(name) };
    }

    pub fn configuredPass(
        name: []const u8,
        options: []const registry_mod.PassOptionAssignment,
    ) Step {
        return .{ .pass = Invocation.configured(name, options) };
    }

    pub fn namedPipeline(name: []const u8) Step {
        return .{ .pipeline = Invocation.named(name) };
    }

    pub fn configuredPipeline(
        name: []const u8,
        options: []const registry_mod.PassOptionAssignment,
    ) Step {
        return .{ .pipeline = Invocation.configured(name, options) };
    }

    pub fn textualPipeline(
        name: []const u8,
        text: []const u8,
        options: []const registry_mod.PassOptionAssignment,
    ) Step {
        return .{ .pipeline = Invocation.textual(name, text, options) };
    }

    pub fn nestedAny(steps: []const Step) Step {
        return .{
            .nested = .{
                .target = .any,
                .steps = steps,
            },
        };
    }

    pub fn nestedOp(name: []const u8, steps: []const Step) Step {
        return .{
            .nested = .{
                .target = .{ .op = name },
                .steps = steps,
            },
        };
    }
};

pub const Plan = struct {
    steps: []const Step,

    pub fn addTo(
        self: Plan,
        registry: *const registry_mod.PassRegistry,
        manager: *pass_mod.PassManager,
    ) anyerror!void {
        try self.addToOp(registry, &manager.root);
    }

    pub fn addToOp(
        self: Plan,
        registry: *const registry_mod.PassRegistry,
        manager: *pass_mod.OpPassManager,
    ) anyerror!void {
        var parsed = pass_mod.OpPassManager.initWithTarget(
            manager.allocator,
            manager.target_kind,
            manager.target_op_name,
        );
        defer parsed.deinit();

        try applySteps(self.steps, registry, &parsed);
        try appendParsedManager(manager, &parsed);
    }

    pub fn write(self: Plan, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeSteps(writer, self.steps);
    }

    pub fn formatAlloc(self: Plan, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try self.write(&out.writer);
        return try out.toOwnedSlice();
    }
};

fn applySteps(
    steps: []const Step,
    registry: *const registry_mod.PassRegistry,
    manager: *pass_mod.OpPassManager,
) anyerror!void {
    for (steps) |step| {
        switch (step) {
            .pass => |invocation| try applyPass(invocation, registry, manager),
            .pipeline => |invocation| try applyPipeline(invocation, registry, manager),
            .nested => |nested| {
                const nested_manager = switch (nested.target) {
                    .any => try manager.nestAny(),
                    .op => |name| try manager.nest(name),
                };
                try applySteps(nested.steps, registry, nested_manager);
            },
        }
    }
}

fn applyPipeline(
    invocation: Invocation,
    registry: *const registry_mod.PassRegistry,
    manager: *pass_mod.OpPassManager,
) anyerror!void {
    const registration = registry.lookupPipeline(invocation.name) orelse return error.UnknownPipeline;
    if (!invocation.hasOptions()) {
        try registration.addTo(manager);
        return;
    }

    try registration.addToWithOptions(
        manager,
        .{ .assignments = invocation.options },
    );
}

fn applyPass(
    invocation: Invocation,
    registry: *const registry_mod.PassRegistry,
    manager: *pass_mod.OpPassManager,
) anyerror!void {
    const registration = registry.lookupPass(invocation.name) orelse return error.UnknownPass;
    if (!invocation.hasOptions()) {
        try registration.addTo(manager);
        return;
    }

    var owned_text: ?[]u8 = null;
    defer if (owned_text) |text| manager.allocator.free(text);
    const option_text = invocation.text orelse blk: {
        owned_text = try formatOptionsAlloc(manager.allocator, invocation.options);
        break :blk owned_text.?;
    };

    try registration.addToWithOptions(
        manager,
        option_text,
        .{ .assignments = invocation.options },
    );
}

fn appendParsedManager(
    dst: *pass_mod.OpPassManager,
    src: *pass_mod.OpPassManager,
) std.mem.Allocator.Error!void {
    try dst.pipeline.ensureUnusedCapacity(dst.allocator, src.pipeline.items.len);
    try dst.nested_managers.ensureUnusedCapacity(dst.allocator, src.nested_managers.items.len);

    for (src.nested_managers.items) |nested| {
        nested.parent = dst;
    }
    dst.pipeline.appendSliceAssumeCapacity(src.pipeline.items);
    dst.nested_managers.appendSliceAssumeCapacity(src.nested_managers.items);

    src.pipeline.clearRetainingCapacity();
    src.nested_managers.clearRetainingCapacity();
}

fn writeSteps(writer: *std.Io.Writer, steps: []const Step) std.Io.Writer.Error!void {
    for (steps, 0..) |step, index| {
        if (index != 0) try writer.writeByte(',');
        switch (step) {
            .pass => |invocation| try writeInvocation(writer, invocation),
            .pipeline => |invocation| try writeInvocation(writer, invocation),
            .nested => |nested| {
                switch (nested.target) {
                    .any => try writer.writeAll("any"),
                    .op => |name| try writer.writeAll(name),
                }
                try writer.writeByte('(');
                try writeSteps(writer, nested.steps);
                try writer.writeByte(')');
            },
        }
    }
}

fn writeInvocation(writer: *std.Io.Writer, invocation: Invocation) std.Io.Writer.Error!void {
    try writer.writeAll(invocation.name);
    if (invocation.text) |text| {
        try writer.writeByte('{');
        try writer.writeAll(text);
        try writer.writeByte('}');
    } else if (invocation.options.len != 0) {
        try writer.writeByte('{');
        try writeOptions(writer, invocation.options);
        try writer.writeByte('}');
    }
}

pub fn formatOptionsAlloc(
    allocator: std.mem.Allocator,
    options: []const registry_mod.PassOptionAssignment,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeOptions(&out.writer, options);
    return try out.toOwnedSlice();
}

pub fn writeOptions(
    writer: *std.Io.Writer,
    options: []const registry_mod.PassOptionAssignment,
) std.Io.Writer.Error!void {
    for (options, 0..) |option, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(option.name);
        if (option.value.len == 0) continue;
        try writer.writeByte('=');
        try writeOptionValue(writer, option.value);
    }
}

fn writeOptionValue(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    if (!optionValueNeedsQuotes(value)) {
        try writer.writeAll(value);
        return;
    }
    try writer.writeByte('"');
    try writer.writeAll(value);
    try writer.writeByte('"');
}

fn optionValueNeedsQuotes(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte) or byte == ',' or byte == '}') return true;
    }
    return false;
}

fn noopPass(_: *pass_mod.PassContext) pass_mod.PassResult {
    return .success;
}

const test_pass = pass_mod.Pass{
    .name = "choir-plan-test-pass",
    .description = "test pass for pass plans",
    .run_fn = noopPass,
};

const test_other_pass = pass_mod.Pass{
    .name = "choir-plan-test-other-pass",
    .description = "second test pass for pass plans",
    .run_fn = noopPass,
};

const test_option_pass = pass_mod.Pass{
    .name = "choir-plan-test-option-pass",
    .description = "test pass for pass plan options",
    .run_fn = noopPass,
};

const test_option_specs = [_]registry_mod.PassOptionSpec{
    .{
        .name = "limit",
        .description = "test limit",
        .kind = .unsigned,
        .default_value = "0",
    },
    .{
        .name = "enabled",
        .description = "test toggle",
        .kind = .boolean,
        .default_value = "false",
    },
};

fn buildTestOptionPass(_: std.mem.Allocator, options: registry_mod.PassOptionSet) anyerror!pass_mod.Pass {
    _ = try options.unsignedValue(usize, "limit", 0);
    _ = try options.boolValue("enabled", false);
    return test_option_pass;
}

fn buildTestPipeline(manager: *pass_mod.OpPassManager) anyerror!void {
    try manager.addPass(test_pass);
}

const test_pass_registration = registry_mod.PassRegistration{
    .name = test_pass.name,
    .description = test_pass.description,
    .pass = test_pass,
};

const test_other_pass_registration = registry_mod.PassRegistration{
    .name = test_other_pass.name,
    .description = test_other_pass.description,
    .pass = test_other_pass,
};

const test_option_pass_registration = registry_mod.PassRegistration{
    .name = test_option_pass.name,
    .description = test_option_pass.description,
    .pass = test_option_pass,
    .options = &test_option_specs,
    .build_with_options = buildTestOptionPass,
};

const test_pipeline = registry_mod.PipelineRegistration{
    .name = "choir-plan-test-pipeline",
    .description = "test pipeline for pass plans",
    .build = buildTestPipeline,
};

fn buildTestPipelineWithOptions(manager: *pass_mod.OpPassManager, options: registry_mod.PassOptionSet) anyerror!void {
    const text = try formatOptionsAlloc(manager.allocator, options.assignments);
    defer manager.allocator.free(text);
    try test_option_pass_registration.addToWithOptions(manager, text, options);
}

const test_option_pipeline = registry_mod.PipelineRegistration{
    .name = "choir-plan-test-option-pipeline",
    .description = "test pipeline with options",
    .build = buildTestPipeline,
    .options = &test_option_specs,
    .build_with_options = buildTestPipelineWithOptions,
};

fn buildTestRegistry(allocator: std.mem.Allocator) !registry_mod.PassRegistry {
    var registry = registry_mod.PassRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.registerPass(test_pass_registration);
    try registry.registerPass(test_other_pass_registration);
    try registry.registerPass(test_option_pass_registration);
    try registry.registerPipeline(test_pipeline);
    try registry.registerPipeline(test_option_pipeline);
    return registry;
}
