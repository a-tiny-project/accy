const std = @import("std");
const pass_mod = @import("pass/root.zig");
const registry_mod = @import("pipeline.zig");

pub const TextualPipelineError = error{
    EmptyElement,
    ExpectedComma,
    ExpectedPassOptionName,
    ExpectedPassOptionValue,
    MissingCloseParen,
    MissingCloseBrace,
    PassOptionsNotSupported,
    UnknownPassOrPipeline,
    UnexpectedCloseParen,
};

pub fn parsePassPipeline(
    registry: *const registry_mod.PassRegistry,
    text: []const u8,
    manager: *pass_mod.PassManager,
) anyerror!void {
    try parseOpPassPipeline(registry, text, &manager.root);
}

pub fn parseOpPassPipeline(
    registry: *const registry_mod.PassRegistry,
    text: []const u8,
    manager: *pass_mod.OpPassManager,
) anyerror!void {
    var parsed = pass_mod.OpPassManager.initWithTarget(
        manager.allocator,
        manager.target_kind,
        manager.target_op_name,
    );
    defer parsed.deinit();

    var parser = Parser{
        .registry = registry,
        .text = text,
    };
    try parser.parsePipeline(&parsed, null);
    try parser.expectDone();
    try appendParsedManager(manager, &parsed);
}

pub fn formatPassManagerPipelineAlloc(
    allocator: std.mem.Allocator,
    manager: *const pass_mod.PassManager,
) ![]u8 {
    return try formatOpPassManagerPipelineAlloc(allocator, &manager.root);
}

pub fn formatOpPassManagerPipelineAlloc(
    allocator: std.mem.Allocator,
    manager: *const pass_mod.OpPassManager,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeOpPassManagerPipeline(&out.writer, manager);
    return try out.toOwnedSlice();
}

pub fn writePassManagerPipeline(
    writer: *std.Io.Writer,
    manager: *const pass_mod.PassManager,
) std.Io.Writer.Error!void {
    try writeOpPassManagerPipeline(writer, &manager.root);
}

pub fn writeOpPassManagerPipeline(
    writer: *std.Io.Writer,
    manager: *const pass_mod.OpPassManager,
) std.Io.Writer.Error!void {
    switch (manager.target_kind) {
        .root => {},
        .any => {
            try writer.writeAll("any(");
        },
        .op => {
            try writer.writeAll(manager.target_op_name.?);
            try writer.writeByte('(');
        },
    }

    for (manager.pipeline.items, 0..) |entry, index| {
        if (index != 0) try writer.writeByte(',');
        switch (entry) {
            .pass => |pass| {
                try writer.writeAll(pass.name);
                if (pass.textual_options) |options| {
                    try writer.writeByte('{');
                    try writer.writeAll(options);
                    try writer.writeByte('}');
                }
            },
            .nested => |nested| try writeOpPassManagerPipeline(writer, nested),
        }
    }

    switch (manager.target_kind) {
        .root => {},
        .any, .op => try writer.writeByte(')'),
    }
}

const Parser = struct {
    registry: *const registry_mod.PassRegistry,
    text: []const u8,
    index: usize = 0,

    fn parsePipeline(
        self: *Parser,
        manager: *pass_mod.OpPassManager,
        close: ?u8,
    ) anyerror!void {
        self.skipWhitespace();
        if (close) |close_char| {
            if (self.consume(close_char)) return;
            if (self.atEnd()) return TextualPipelineError.MissingCloseParen;
        } else if (self.atEnd()) {
            return;
        } else if (self.peek() == ')') {
            return TextualPipelineError.UnexpectedCloseParen;
        }

        while (true) {
            if (self.atEnd()) {
                if (close != null) return TextualPipelineError.MissingCloseParen;
                return;
            }

            self.skipWhitespace();
            if (self.atEnd()) return TextualPipelineError.EmptyElement;
            if (self.peek() == ')') return TextualPipelineError.UnexpectedCloseParen;

            const start = self.index;
            while (!self.atEnd() and !isNameTerminator(self.peek())) {
                self.index += 1;
            }

            const name = std.mem.trim(u8, self.text[start..self.index], " \t\r\n");
            if (name.len == 0) return TextualPipelineError.EmptyElement;

            self.skipWhitespace();
            var option_block: ?ParsedOptionBlock = null;
            defer if (option_block) |*block| block.deinit(manager.allocator);
            if (self.consume('{')) {
                option_block = try self.parseOptionBlock(manager.allocator);
                self.skipWhitespace();
            }
            if (self.consume('(')) {
                if (option_block != null) return TextualPipelineError.ExpectedComma;
                const nested = if (std.mem.eql(u8, name, "any"))
                    try manager.nestAny()
                else
                    try manager.nest(name);
                try self.parsePipeline(nested, ')');
            } else if (self.registry.lookupPipeline(name)) |registration| {
                if (option_block) |block| {
                    try registration.addToWithOptions(manager, .{ .assignments = block.assignments });
                } else {
                    try registration.addTo(manager);
                }
            } else if (self.registry.lookupPass(name)) |registration| {
                if (option_block) |block| {
                    try registration.addToWithOptions(
                        manager,
                        block.text,
                        .{ .assignments = block.assignments },
                    );
                } else {
                    try registration.addTo(manager);
                }
            } else {
                return TextualPipelineError.UnknownPassOrPipeline;
            }
            self.skipWhitespace();

            if (self.consume(',')) {
                self.skipWhitespace();
                if (self.atEnd()) return TextualPipelineError.EmptyElement;
                if (close) |close_char| {
                    if (self.peek() == close_char) return TextualPipelineError.EmptyElement;
                } else if (self.peek() == ')') {
                    return TextualPipelineError.UnexpectedCloseParen;
                }
                continue;
            }

            if (close) |close_char| {
                if (self.consume(close_char)) return;
                if (self.atEnd()) return TextualPipelineError.MissingCloseParen;
            } else if (self.atEnd()) {
                return;
            } else if (self.peek() == ')') {
                return TextualPipelineError.UnexpectedCloseParen;
            }

            return TextualPipelineError.ExpectedComma;
        }
    }

    fn parseOptionBlock(self: *Parser, allocator: std.mem.Allocator) anyerror!ParsedOptionBlock {
        const text_start = self.index;
        var assignments: std.ArrayListUnmanaged(registry_mod.PassOptionAssignment) = .empty;
        errdefer assignments.deinit(allocator);

        while (true) {
            self.skipWhitespace();
            if (self.atEnd()) return TextualPipelineError.MissingCloseBrace;
            if (self.consume('}')) {
                return .{
                    .text = self.text[text_start .. self.index - 1],
                    .assignments = try assignments.toOwnedSlice(allocator),
                };
            }

            const name_start = self.index;
            while (!self.atEnd() and isOptionNameChar(self.peek())) {
                self.index += 1;
            }
            const option_name = self.text[name_start..self.index];
            if (option_name.len == 0) return TextualPipelineError.ExpectedPassOptionName;

            self.skipWhitespace();
            const option_value = if (self.consume('=')) value: {
                self.skipWhitespace();
                break :value try self.parseOptionValue();
            } else "";
            try assignments.append(allocator, .{
                .name = option_name,
                .value = option_value,
            });

            self.skipWhitespace();
            if (self.consume(',')) continue;
            if (self.consume('}')) {
                return .{
                    .text = self.text[text_start .. self.index - 1],
                    .assignments = try assignments.toOwnedSlice(allocator),
                };
            }
        }
    }

    fn parseOptionValue(self: *Parser) TextualPipelineError![]const u8 {
        if (self.atEnd()) return TextualPipelineError.ExpectedPassOptionValue;
        if (self.consume('"')) {
            const start = self.index;
            while (!self.atEnd() and self.peek() != '"') {
                self.index += 1;
            }
            if (self.atEnd()) return TextualPipelineError.ExpectedPassOptionValue;
            const value = self.text[start..self.index];
            self.index += 1;
            if (value.len == 0) return TextualPipelineError.ExpectedPassOptionValue;
            return value;
        }

        const start = self.index;
        while (!self.atEnd() and !isOptionValueTerminator(self.peek())) {
            self.index += 1;
        }
        const value = self.text[start..self.index];
        if (value.len == 0) return TextualPipelineError.ExpectedPassOptionValue;
        return value;
    }

    fn expectDone(self: *Parser) TextualPipelineError!void {
        self.skipWhitespace();
        if (self.atEnd()) return;
        if (self.peek() == ')') return TextualPipelineError.UnexpectedCloseParen;
        return TextualPipelineError.ExpectedComma;
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.atEnd() and std.ascii.isWhitespace(self.text[self.index])) {
            self.index += 1;
        }
    }

    fn consume(self: *Parser, ch: u8) bool {
        if (self.atEnd() or self.text[self.index] != ch) return false;
        self.index += 1;
        return true;
    }

    fn peek(self: *const Parser) u8 {
        return self.text[self.index];
    }

    fn atEnd(self: *const Parser) bool {
        return self.index >= self.text.len;
    }
};

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

fn isNameTerminator(ch: u8) bool {
    return ch == ',' or ch == '(' or ch == ')' or ch == '{' or ch == '}' or std.ascii.isWhitespace(ch);
}

fn isOptionNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

fn isOptionValueTerminator(ch: u8) bool {
    return ch == ',' or ch == '}' or std.ascii.isWhitespace(ch);
}

const ParsedOptionBlock = struct {
    text: []const u8,
    assignments: []registry_mod.PassOptionAssignment,

    fn deinit(self: *ParsedOptionBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.assignments);
    }
};

fn noopPass(_: *pass_mod.PassContext) pass_mod.PassResult {
    return .success;
}

const textual_test_pass = pass_mod.Pass{
    .name = "choir-textual-test-pass",
    .description = "test pass for textual pipeline parsing",
    .run_fn = noopPass,
};

const textual_test_pass_registration = registry_mod.PassRegistration{
    .name = textual_test_pass.name,
    .description = textual_test_pass.description,
    .pass = textual_test_pass,
};

const textual_option_choices = [_]registry_mod.PassOptionChoice{
    .{ .name = "fast" },
    .{ .name = "slow" },
};

const textual_test_option_specs = [_]registry_mod.PassOptionSpec{
    .{
        .name = "mode",
        .description = "test mode",
        .kind = .choice,
        .choices = &textual_option_choices,
        .default_value = "fast",
    },
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

const textual_test_option_pass = pass_mod.Pass{
    .name = "choir-textual-test-option-pass",
    .description = "test pass for textual pipeline options",
    .run_fn = noopPass,
};

fn buildTextualTestOptionPass(_: std.mem.Allocator, options: registry_mod.PassOptionSet) anyerror!pass_mod.Pass {
    _ = options.choiceValue("mode", "fast");
    _ = try options.unsignedValue(usize, "limit", 0);
    _ = try options.boolValue("enabled", false);
    return textual_test_option_pass;
}

const textual_test_option_pass_registration = registry_mod.PassRegistration{
    .name = textual_test_option_pass.name,
    .description = textual_test_option_pass.description,
    .pass = textual_test_option_pass,
    .options = &textual_test_option_specs,
    .build_with_options = buildTextualTestOptionPass,
};

fn buildTextualTestPipeline(manager: *pass_mod.OpPassManager) anyerror!void {
    try manager.addPass(textual_test_pass);
}

const textual_test_pipeline = registry_mod.PipelineRegistration{
    .name = "choir-textual-test-pipeline",
    .description = "test textual pipeline registration",
    .build = buildTextualTestPipeline,
};

const textual_pipeline_option_specs = [_]registry_mod.PassOptionSpec{
    .{
        .name = "limit",
        .description = "test pipeline limit",
        .kind = .unsigned,
        .default_value = "0",
    },
    .{
        .name = "enabled",
        .description = "test pipeline toggle",
        .kind = .boolean,
        .default_value = "false",
    },
};

fn buildTextualTestPipelineWithOptions(
    manager: *pass_mod.OpPassManager,
    options: registry_mod.PassOptionSet,
) anyerror!void {
    _ = try options.boolValue("enabled", false);
    const limit = options.get("limit") orelse "0";
    const option_text = try std.fmt.allocPrint(manager.allocator, "limit={s}", .{limit});
    defer manager.allocator.free(option_text);
    try textual_test_option_pass_registration.addToWithOptions(
        manager,
        option_text,
        options,
    );
}

const textual_test_option_pipeline = registry_mod.PipelineRegistration{
    .name = "choir-textual-test-option-pipeline",
    .description = "test textual pipeline options",
    .build = buildTextualTestPipeline,
    .options = &textual_pipeline_option_specs,
    .build_with_options = buildTextualTestPipelineWithOptions,
};

fn buildTextualRegistry(allocator: std.mem.Allocator) !registry_mod.PassRegistry {
    var registry = registry_mod.PassRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.registerPass(textual_test_pass_registration);
    try registry.registerPass(textual_test_option_pass_registration);
    try registry.registerPipeline(textual_test_pipeline);
    try registry.registerPipeline(textual_test_option_pipeline);
    return registry;
}

test "textual pipeline parses registered passes and pipelines" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(&registry, " choir-textual-test-pass , choir-textual-test-pipeline ", &manager);

    try std.testing.expectEqual(@as(usize, 2), manager.root.pipeline.items.len);

    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("choir-textual-test-pass,choir-textual-test-pass", text);
}

test "textual pipeline parses explicit operation nesting" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(&registry, "test.op(choir-textual-test-pass)", &manager);

    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);
    switch (manager.root.pipeline.items[0]) {
        .nested => |nested| {
            try std.testing.expectEqualStrings("test.op", nested.target_op_name.?);
            try std.testing.expectEqual(@as(usize, 1), nested.pipeline.items.len);
        },
        .pass => return error.TestExpectedNestedPassManager,
    }

    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test.op(choir-textual-test-pass)", text);
}

test "textual pipeline parses op-agnostic any nesting" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(&registry, "any(choir-textual-test-pass)", &manager);

    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);
    switch (manager.root.pipeline.items[0]) {
        .nested => |nested| {
            try std.testing.expectEqual(pass_mod.OpPassManagerTargetKind.any, nested.target_kind);
            try std.testing.expectEqual(@as(?[]const u8, null), nested.target_op_name);
            try std.testing.expectEqual(@as(usize, 1), nested.pipeline.items.len);
        },
        .pass => return error.TestExpectedNestedPassManager,
    }

    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("any(choir-textual-test-pass)", text);
}

test "textual pipeline parses pass options and formats them" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(
        &registry,
        "choir-textual-test-option-pass{mode=slow,limit=7}",
        &manager,
    );

    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);
    switch (manager.root.pipeline.items[0]) {
        .pass => |pass| {
            try std.testing.expectEqualStrings(textual_test_option_pass.name, pass.name);
            try std.testing.expectEqualStrings("mode=slow,limit=7", pass.textual_options.?);
        },
        .nested => return error.TestExpectedPass,
    }

    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("choir-textual-test-option-pass{mode=slow,limit=7}", text);
}

test "textual pipeline parses MLIR-style boolean pass option values" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(
        &registry,
        "choir-textual-test-option-pass{enabled,limit=7},choir-textual-test-option-pass{enabled=1},choir-textual-test-option-pass{enabled=0}",
        &manager,
    );

    try std.testing.expectEqual(@as(usize, 3), manager.root.pipeline.items.len);
    switch (manager.root.pipeline.items[0]) {
        .pass => |pass| try std.testing.expectEqualStrings("enabled,limit=7", pass.textual_options.?),
        .nested => return error.TestExpectedPass,
    }
    switch (manager.root.pipeline.items[1]) {
        .pass => |pass| try std.testing.expectEqualStrings("enabled=1", pass.textual_options.?),
        .nested => return error.TestExpectedPass,
    }
    switch (manager.root.pipeline.items[2]) {
        .pass => |pass| try std.testing.expectEqualStrings("enabled=0", pass.textual_options.?),
        .nested => return error.TestExpectedPass,
    }
}

test "textual pipeline parses pass options inside nested managers" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(
        &registry,
        "test.op(choir-textual-test-option-pass{mode=slow limit=11})",
        &manager,
    );

    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test.op(choir-textual-test-option-pass{mode=slow limit=11})", text);
}

test "textual pipeline parses registered pipeline options" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(
        &registry,
        "choir-textual-test-option-pipeline{limit=13}",
        &manager,
    );

    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);
    switch (manager.root.pipeline.items[0]) {
        .pass => |pass| {
            try std.testing.expectEqualStrings(textual_test_option_pass.name, pass.name);
            try std.testing.expectEqualStrings("limit=13", pass.textual_options.?);
        },
        .nested => return error.TestExpectedPass,
    }

    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("choir-textual-test-option-pass{limit=13}", text);
}

test "textual pipeline validates declared pass options" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectError(
        error.UnknownPassOption,
        parsePassPipeline(&registry, "choir-textual-test-option-pass{missing=1}", &manager),
    );
    try std.testing.expectError(
        error.DuplicatePassOption,
        parsePassPipeline(&registry, "choir-textual-test-option-pass{limit=1,limit=2}", &manager),
    );
    try std.testing.expectError(
        error.InvalidPassOptionValue,
        parsePassPipeline(&registry, "choir-textual-test-option-pass{mode=medium}", &manager),
    );
    try std.testing.expectError(
        error.PassOptionsNotSupported,
        parsePassPipeline(&registry, "choir-textual-test-pass{limit=1}", &manager),
    );
    try std.testing.expectError(
        error.UnknownPassOption,
        parsePassPipeline(&registry, "choir-textual-test-option-pipeline{missing=1}", &manager),
    );
    try std.testing.expectError(
        error.InvalidPassOptionValue,
        parsePassPipeline(&registry, "choir-textual-test-option-pipeline{limit=nope}", &manager),
    );
    try std.testing.expectError(
        error.MissingPassOptionValue,
        parsePassPipeline(&registry, "choir-textual-test-option-pipeline{limit}", &manager),
    );
    try std.testing.expectError(
        error.PassOptionsNotSupported,
        parsePassPipeline(&registry, "choir-textual-test-pipeline{limit=1}", &manager),
    );
}

test "textual pipeline accepts empty root and nested pipelines" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(&registry, " \t\n ", &manager);
    try std.testing.expectEqual(@as(usize, 0), manager.root.pipeline.items.len);

    try parsePassPipeline(&registry, "test.empty()", &manager);
    const text = try formatPassManagerPipelineAlloc(std.testing.allocator, &manager);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test.empty()", text);
}

test "textual pipeline parse errors do not mutate the destination manager" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try parsePassPipeline(&registry, "choir-textual-test-pass", &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);

    try std.testing.expectError(
        TextualPipelineError.UnknownPassOrPipeline,
        parsePassPipeline(&registry, "choir-textual-test-pipeline,missing-pass", &manager),
    );
    try std.testing.expectEqual(@as(usize, 1), manager.root.pipeline.items.len);
}

test "textual pipeline reports malformed nesting" {
    var registry = try buildTextualRegistry(std.testing.allocator);
    defer registry.deinit();

    var manager = pass_mod.PassManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectError(
        TextualPipelineError.MissingCloseParen,
        parsePassPipeline(&registry, "test.op(choir-textual-test-pass", &manager),
    );
    try std.testing.expectError(
        TextualPipelineError.UnexpectedCloseParen,
        parsePassPipeline(&registry, "choir-textual-test-pass)", &manager),
    );
    try std.testing.expectError(
        TextualPipelineError.EmptyElement,
        parsePassPipeline(&registry, "choir-textual-test-pass,", &manager),
    );
}
