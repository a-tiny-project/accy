const std = @import("std");
const catalog = @import("root.zig");
const model = catalog.model;

const Capture = struct {
    allocator: std.mem.Allocator,
    source: catalog.source.Context,
    steps: std.ArrayList(*std.Build.Step) = .empty,
    step_ids: std.AutoHashMapUnmanaged(*std.Build.Step, u32) = .empty,
    modules: std.ArrayList(*std.Build.Module) = .empty,
    module_ids: std.AutoHashMapUnmanaged(*std.Build.Module, u32) = .empty,
    edges: u32 = 0,

    fn addStep(self: *Capture, step: *std.Build.Step) !u32 {
        if (self.step_ids.get(step)) |id| return id;
        if (self.steps.items.len == model.maximum_steps) return error.BuildFactStepLimit;
        const id: u32 = @intCast(self.steps.items.len);
        try self.steps.append(self.allocator, step);
        try self.step_ids.put(self.allocator, step, id);
        return id;
    }

    fn addModule(self: *Capture, module: *std.Build.Module) !u32 {
        if (self.module_ids.get(module)) |id| return id;
        if (self.modules.items.len == model.maximum_modules) return error.BuildFactModuleLimit;
        const id: u32 = @intCast(self.modules.items.len);
        try self.modules.append(self.allocator, module);
        try self.module_ids.put(self.allocator, module, id);
        return id;
    }

    fn addEdges(self: *Capture, count: usize) !void {
        if (count > model.maximum_edges - self.edges) return error.BuildFactEdgeLimit;
        self.edges += @intCast(count);
    }

    fn readStep(self: *Capture, value: *std.Build.Step) !model.Step {
        try self.addEdges(value.dependencies.items.len);
        const dependencies = try self.allocator.alloc(u32, value.dependencies.items.len);
        for (dependencies, value.dependencies.items) |*id, dependency| {
            id.* = try self.addStep(dependency);
        }
        var result = model.Step{
            .name = value.name,
            .kind = @tagName(value.tag),
            .dependencies = dependencies,
        };
        if (value.cast(std.Build.Step.Compile)) |compile| result.compile = .{
            .name = compile.name,
            .kind = @tagName(compile.kind),
            .module = try self.addModule(compile.root_module),
        };
        if (value.cast(std.Build.Step.Run)) |run| result.run = try self.readRun(run);
        return result;
    }

    fn readModule(self: *Capture, value: *std.Build.Module) !model.Module {
        const names = try self.allocator.dupe([]const u8, value.import_table.keys());
        try self.addEdges(names.len);
        std.mem.sort([]const u8, names, {}, less);
        const imports = try self.allocator.alloc(model.Import, names.len);
        for (imports, names) |*item, name| item.* = .{
            .name = name,
            .module = try self.addModule(value.import_table.get(name).?),
        };
        return .{ .source = try self.source.path(value.root_source_file), .imports = imports };
    }

    fn readRun(self: *Capture, value: *std.Build.Step.Run) !model.Run {
        if (value.argv.items.len > model.maximum_arguments) return error.BuildFactArgumentLimit;
        const arguments = try self.allocator.alloc(model.Argument, value.argv.items.len);
        for (arguments, value.argv.items) |*argument, arg| argument.* = try self.readArgument(arg);
        return .{
            .cwd = try self.source.path(value.cwd orelse value.step.owner.path(".")),
            .arguments = arguments,
        };
    }

    fn readArgument(self: *Capture, value: std.Build.Step.Run.Arg) !model.Argument {
        return switch (value) {
            .bytes => |bytes| .{ .kind = .bytes, .value = bytes },
            .artifact => |arg| .{
                .kind = .artifact,
                .artifact = try self.addStep(&arg.artifact.step),
                .prefix = arg.prefix,
                .suffix = arg.suffix,
            },
            inline .lazy_path, .decorated_directory, .file_content => |arg, tag| .{
                .kind = switch (tag) {
                    .lazy_path => .path,
                    .decorated_directory => .directory,
                    .file_content => .file_content,
                    else => unreachable,
                },
                .path = try self.source.path(arg.lazy_path),
                .prefix = arg.prefix,
                .suffix = arg.suffix,
            },
            .output_file, .output_file_dep, .output_directory => |arg| .{
                .kind = .output,
                .value = arg.basename,
                .prefix = arg.prefix,
                .suffix = arg.suffix,
            },
            .passthru => .{ .kind = .passthru },
            // No registered step selects a third-party executor per argument.
            .enable_darling,
            .enable_qemu,
            .enable_rosetta,
            .enable_wasmtime,
            .enable_wine,
            => error.BuildFactExecutorToggle,
        };
    }
};

pub fn capture(b: *std.Build, excluded: ?*std.Build.Step) !model.Catalog {
    var state = Capture{ .allocator = b.graph.arena, .source = try catalog.source.Context.init(b) };
    defer state.source.deinit();
    const names = try b.graph.arena.dupe([]const u8, b.top_level_steps.keys());
    std.mem.sort([]const u8, names, {}, less);
    var roots: std.ArrayList(model.Root) = .empty;
    for (names) |name| {
        const step = &b.top_level_steps.get(name).?.step;
        if (step == excluded) continue;
        try roots.append(b.graph.arena, .{
            .name = name,
            .step = try state.addStep(step),
            .registration_files = try state.source.registration(step),
        });
    }
    var steps: std.ArrayList(model.Step) = .empty;
    var cursor: u32 = 0;
    while (cursor < state.steps.items.len) : (cursor += 1) {
        try steps.append(b.graph.arena, try state.readStep(state.steps.items[cursor]));
    }
    var modules: std.ArrayList(model.Module) = .empty;
    cursor = 0;
    while (cursor < state.modules.items.len) : (cursor += 1) {
        try modules.append(b.graph.arena, try state.readModule(state.modules.items[cursor]));
    }
    return .{
        .schema = model.schema,
        .build_root = state.source.root,
        .roots = roots.items,
        .steps = steps.items,
        .modules = modules.items,
    };
}

pub fn encode(b: *std.Build, excluded: ?*std.Build.Step) ![]const u8 {
    const facts = try capture(b, excluded);
    var output = std.Io.Writer.Allocating.init(b.graph.arena);
    try std.json.Stringify.value(facts, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    if (output.written().len > model.maximum_bytes) return error.BuildFactByteLimit;
    return output.toOwnedSlice();
}

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
