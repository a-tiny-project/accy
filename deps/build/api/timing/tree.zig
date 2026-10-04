const std = @import("std");
const command = @import("command.zig");
const Io = std.Io;

/// The most declared run-time inputs one test binary may copy into its tree.
pub const inputs_max = 64;

const root_name = "root";

pub const Input = struct {
    /// Repository-relative path the tests open through their working directory.
    path: []const u8,
    /// Build-resolved file whose bytes the build hashed into the run's cache key.
    source: []const u8,
};

/// A private working tree that holds only the declared inputs of one cached test run.
pub const Plan = struct {
    output: []const u8,
    cwd: []const u8,
    inputs: [inputs_max]Input = undefined,
    input_count: usize = 0,

    pub fn declared(self: *const Plan) []const Input {
        std.debug.assert(self.input_count <= inputs_max);
        return self.inputs[0..self.input_count];
    }
};

pub const PlanError = error{
    DuplicateTree,
    DuplicateCwd,
    MissingTree,
    MissingCwd,
    TooManyInputs,
    InvalidTreePath,
    InvalidInput,
    DuplicateInput,
};

/// Reads the tree flags. A run without `--test-tree` keeps the caller's working directory.
pub fn plan(iterator: anytype) PlanError!?Plan {
    var output: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var result: Plan = .{ .output = "", .cwd = "" };
    var any_input = false;
    while (iterator.next()) |argument| {
        if (value(argument, command.tree_flag, iterator)) |path| {
            if (output != null) return error.DuplicateTree;
            if (path.len == 0) return error.InvalidTreePath;
            output = path;
        } else if (value(argument, command.cwd_flag, iterator)) |path| {
            if (cwd != null) return error.DuplicateCwd;
            if (!relative(path)) return error.InvalidTreePath;
            cwd = path;
        } else if (value(argument, command.input_flag, iterator)) |text| {
            any_input = true;
            const split = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidInput;
            const input: Input = .{ .path = text[0..split], .source = text[split + 1 ..] };
            if (!relative(input.path) or input.source.len == 0) return error.InvalidInput;
            for (result.declared()) |existing| {
                if (std.mem.eql(u8, existing.path, input.path)) return error.DuplicateInput;
            }
            if (result.input_count == inputs_max) return error.TooManyInputs;
            result.inputs[result.input_count] = input;
            result.input_count += 1;
        }
    }
    const tree = output orelse {
        if (cwd != null or any_input) return error.MissingTree;
        return null;
    };
    result.output = tree;
    result.cwd = cwd orelse return error.MissingCwd;
    return result;
}

fn value(argument: []const u8, flag: []const u8, iterator: anytype) ?[]const u8 {
    if (std.mem.eql(u8, argument, flag)) return iterator.next() orelse "";
    if (argument.len > flag.len and argument[flag.len] == '=' and
        std.mem.eql(u8, argument[0..flag.len], flag)) return argument[flag.len + 1 ..];
    return null;
}

/// Accepts a nonempty relative path whose every component names an entry below its base.
pub fn relative(path: []const u8) bool {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes or path[0] == '/') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// The prepared tree. Passing runs remove it so the cached output keeps only the report.
pub const Workspace = struct {
    output: Io.Dir,

    /// Leaves the tree and deletes it with everything the tests wrote under it.
    pub fn finish(self: Workspace, io: Io) !void {
        try std.process.setCurrentDir(io, self.output);
        try self.output.deleteTree(io, root_name);
        self.output.close(io);
    }
};

/// Copies each declared input to its repository-relative path under the tree, then makes
/// the tree's copy of `cwd` the working directory. Input sources resolve against the
/// working directory the build gave the run, before the change.
pub fn prepare(io: Io, selected: *const Plan) !Workspace {
    const invoked = Io.Dir.cwd();
    var output = try invoked.openDir(io, selected.output, .{});
    errdefer output.close(io);
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    try output.deleteTree(io, root_name);
    const cwd_path = try std.fmt.bufPrint(&path_storage, root_name ++ "/{s}", .{selected.cwd});
    try output.createDirPath(io, cwd_path);
    for (selected.declared()) |input| {
        const destination = try std.fmt.bufPrint(&path_storage, root_name ++ "/{s}", .{input.path});
        if (std.fs.path.dirname(destination)) |parent| try output.createDirPath(io, parent);
        try Io.Dir.copyFile(invoked, input.source, output, destination, io, .{});
    }
    var working = try output.openDir(io, try std.fmt.bufPrint(
        &path_storage,
        root_name ++ "/{s}",
        .{selected.cwd},
    ), .{});
    defer working.close(io);
    try std.process.setCurrentDir(io, working);
    return .{ .output = output };
}

const SliceIterator = struct {
    values: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index >= self.values.len) return null;
        defer self.index += 1;
        return self.values[self.index];
    }
};

fn planSlice(values: []const []const u8) PlanError!?Plan {
    var iterator = SliceIterator{ .values = values };
    return plan(&iterator);
}

test "a run without a tree keeps the caller's working directory" {
    try std.testing.expectEqual(@as(?Plan, null), try planSlice(&.{ "--test-filter", "x" }));
}

test "tree flags read joined and separate values" {
    const host_task = "verification/models/chic/tla/HostTask.tla";
    const selected = (try planSlice(&.{
        "--test-tree=/cache/o/tree",
        "--test-cwd",
        "research/chic",
        "--test-input=" ++ host_task ++ "=/repo/" ++ host_task,
        "--test-input",
        "research/chic/fixture.txt=fixture.txt",
    })).?;
    try std.testing.expectEqualStrings("/cache/o/tree", selected.output);
    try std.testing.expectEqualStrings("research/chic", selected.cwd);
    try std.testing.expectEqual(@as(usize, 2), selected.declared().len);
    try std.testing.expectEqualStrings(host_task, selected.declared()[0].path);
    try std.testing.expectEqualStrings("fixture.txt", selected.declared()[1].source);
}

fn expectRefused(expected: PlanError, values: []const []const u8) !void {
    try std.testing.expectError(expected, planSlice(values));
}

test "tree flags fail closed" {
    try expectRefused(error.MissingTree, &.{ "--test-cwd", "research/chic" });
    try expectRefused(error.MissingTree, &.{"--test-input=a=b"});
    try expectRefused(error.MissingCwd, &.{"--test-tree=o"});
    try expectRefused(error.DuplicateTree, &.{ "--test-tree=o", "--test-tree=p" });
    try expectRefused(error.InvalidTreePath, &.{ "--test-tree=o", "--test-cwd=../x" });
    const tree_cwd = [_][]const u8{ "--test-tree=o", "--test-cwd=a" };
    try expectRefused(error.InvalidInput, &(tree_cwd ++ .{"--test-input=/abs=b"}));
    try expectRefused(error.InvalidInput, &(tree_cwd ++ .{"--test-input=a/../b=b"}));
    try expectRefused(error.InvalidInput, &(tree_cwd ++ .{"--test-input=nosource"}));
    try expectRefused(
        error.DuplicateInput,
        &(tree_cwd ++ .{ "--test-input=x=b", "--test-input=x=c" }),
    );
}

test "relative paths name entries below their base" {
    try std.testing.expect(relative("research/chic"));
    try std.testing.expect(relative("a"));
    for ([_][]const u8{ "", "/a", "a/" ++ "/b", "a/./b", "../a", "a/..", "a/" }) |path| {
        try std.testing.expect(!relative(path));
    }
}
