const std = @import("std");

pub const Tool = struct {
    name: []const u8,
    build_step: []const u8,
    retire_tool: ?[]const u8 = null,
    install_optimize: ?std.builtin.OptimizeMode = null,
    /// Leaf runtime artifacts installed by the same publication cohort.
    runtime_artifacts: []const []const u8 = &.{},
};

pub const ToolAvailability = struct {
    style: bool,
    stardust: bool,
};

pub const HookProfile = enum {
    native,
    chic,
};

const chic_fmt_tool: Tool = .{
    .name = "chic-fmt",
    .build_step = "chic-fmt-tool",
};
/// Gate uses Small until compiler 0.17.0-dev.1465+8b2d0ce21 can build it
/// at ReleaseFast; then remove this override.
const gate_tool: Tool = .{
    .name = "gate",
    .build_step = "gate-tool",
    .install_optimize = .small,
};
const issue_tool: Tool = .{ .name = "issue", .build_step = "issue-tool" };
pub const loom_tool: Tool = .{
    .name = "loom",
    .build_step = "loom-tool",
    .runtime_artifacts = &loom_runtime_artifacts,
};
/// Cross-target delivery images build on their own lane. Keeping them off
/// the controller's host tool step keeps four waves of ReleaseSafe cross
/// compilation out of every ordinary host tool build; publication still ships
/// them with the host tool because they are its declared runtime artifacts.
pub const loom_delivery_step = "loom-delivery";
pub const loom_companion_tools = [_]Tool{
    .{ .name = "loom-x86_64-linux-worker", .build_step = loom_delivery_step },
    .{ .name = "loom-aarch64-linux-worker", .build_step = loom_delivery_step },
    .{ .name = "loom-x86_64-darwin-worker", .build_step = loom_delivery_step },
    .{ .name = "loom-aarch64-darwin-worker", .build_step = loom_delivery_step },
    .{ .name = "loom-x86_64-linux-site-agent", .build_step = loom_delivery_step },
    .{ .name = "loom-aarch64-linux-site-agent", .build_step = loom_delivery_step },
    .{ .name = "loom-x86_64-darwin-site-agent", .build_step = loom_delivery_step },
    .{ .name = "loom-aarch64-darwin-site-agent", .build_step = loom_delivery_step },
};
const loom_runtime_artifacts = blk: {
    var names: [loom_companion_tools.len][]const u8 = undefined;
    for (loom_companion_tools, 0..) |tool, index| names[index] = tool.name;
    break :blk names;
};
const licenses_tool: Tool = .{
    .name = "licenses",
    .build_step = "licenses-tool",
};
const package_discipline_tool: Tool = .{
    .name = "package-discipline",
    .build_step = "package-discipline-tool",
};
const repository_policy_tool: Tool = .{
    .name = "repository-policy",
    .build_step = "repository-policy-tool",
};
const sdfii_symbols_tool: Tool = .{
    .name = "sdfii-symbols",
    .build_step = "sdfii-symbols-tool",
};
const source_closure_tool: Tool = .{
    .name = "source-closure",
    .build_step = "source-closure-tool",
};
const style_tool: Tool = .{ .name = "style", .build_step = "style-tool" };
const wiring_tool: Tool = .{ .name = "wiring", .build_step = "wiring-tool" };

const tool_prefix = [_]Tool{
    .{ .name = "ask", .build_step = "ask-tool" },
    chic_fmt_tool,
    .{ .name = "clip", .build_step = "clip-tool" },
    .{ .name = "diagrams", .build_step = "diagrams-tool" },
    .{ .name = "forum", .build_step = "forum-tool" },
    gate_tool,
    .{ .name = "glom", .build_step = "glom-tool" },
    issue_tool,
    licenses_tool,
    loom_tool,
    package_discipline_tool,
    .{ .name = "peek", .build_step = "peek-tool" },
    .{ .name = "reel", .build_step = "reel-tool" },
    repository_policy_tool,
    sdfii_symbols_tool,
    source_closure_tool,
    .{ .name = "smg", .build_step = "smg-tool" },
    .{ .name = "tempo", .build_step = "tempo-tool" },
    .{ .name = "tiny", .build_step = "tiny-tool" },
    .{
        .name = "verification-catalog",
        .build_step = "verification-catalog-tool",
    },
};

const held_style_tools = [_]Tool{style_tool};
const held_stardust_tools = [_]Tool{.{
    .name = "stardust",
    .build_step = "stardust-tool",
    .retire_tool = "verify",
}};

const tool_suffix = [_]Tool{
    .{ .name = "web", .build_step = "web-tool" },
    wiring_tool,
};

const public_tools = tool_prefix ++ tool_suffix;
const style_tools = tool_prefix ++ held_style_tools ++ tool_suffix;
const stardust_tools = tool_prefix ++ held_stardust_tools ++ tool_suffix;
const all_tools =
    tool_prefix ++ held_style_tools ++ held_stardust_tools ++ tool_suffix;
pub const tool_count_max = all_tools.len;

pub fn tools(comptime availability: ToolAvailability) []const Tool {
    return if (availability.style and availability.stardust)
        &all_tools
    else if (availability.style)
        &style_tools
    else if (availability.stardust)
        &stardust_tools
    else
        &public_tools;
}

const native_hook_prefix = [_]Tool{
    gate_tool,
    licenses_tool,
    package_discipline_tool,
    repository_policy_tool,
    sdfii_symbols_tool,
};
const native_hook_suffix = [_]Tool{wiring_tool};
const public_native_hook_tools = native_hook_prefix ++ native_hook_suffix;
const all_native_hook_tools =
    native_hook_prefix ++ [_]Tool{style_tool} ++ native_hook_suffix;
const chic_hook_tools = [_]Tool{chic_fmt_tool};

pub fn hookTools(
    comptime selected_profile: HookProfile,
    comptime include_style: bool,
) []const Tool {
    return switch (selected_profile) {
        .native => if (include_style)
            &all_native_hook_tools
        else
            &public_native_hook_tools,
        .chic => &chic_hook_tools,
    };
}

test "installed tool names and build steps are unique" {
    const active_tools = tools(.{ .style = true, .stardust = true });
    for (active_tools, 0..) |tool, index| {
        try std.testing.expect(tool.name.len != 0);
        try std.testing.expect(tool.build_step.len != 0);
        if (tool.retire_tool) |retire_tool| {
            try std.testing.expect(retire_tool.len != 0);
            for (active_tools) |other| {
                try std.testing.expect(!std.mem.eql(
                    u8,
                    retire_tool,
                    other.name,
                ));
            }
        }
        for (active_tools[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, tool.name, other.name));
            try std.testing.expect(!std.mem.eql(
                u8,
                tool.build_step,
                other.build_step,
            ));
            if (tool.retire_tool != null and other.retire_tool != null) {
                try std.testing.expect(!std.mem.eql(
                    u8,
                    tool.retire_tool.?,
                    other.retire_tool.?,
                ));
            }
        }
    }
}

test "Style and Stardust tool availability is independent" {
    try expectTools(
        tools(.{ .style = true, .stardust = false }),
        "style",
        "stardust",
    );
    try expectTools(
        tools(.{ .style = false, .stardust = true }),
        "stardust",
        "style",
    );
}

fn expectTools(
    values: []const Tool,
    included: []const u8,
    excluded: []const u8,
) !void {
    var found_included = false;
    for (values) |tool| {
        if (std.mem.eql(u8, tool.name, included)) found_included = true;
        try std.testing.expect(!std.mem.eql(u8, tool.name, excluded));
    }
    try std.testing.expect(found_included);
}

test "Loom companion artifacts build on the delivery lane" {
    try std.testing.expectEqual(@as(usize, 8), loom_companion_tools.len);
    try std.testing.expectEqualStrings("loom-tool", loom_tool.build_step);
    try std.testing.expectEqualStrings("loom-delivery", loom_delivery_step);
    for (loom_companion_tools, 0..) |tool, index| {
        try std.testing.expectEqualStrings(loom_delivery_step, tool.build_step);
        try std.testing.expect(!std.mem.eql(u8, loom_tool.name, tool.name));
        for (loom_companion_tools[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, tool.name, other.name));
        }
    }
}

test "native and Chic hook profiles contain only their executables" {
    const public_native_expected = [_][]const u8{
        "gate",
        "licenses",
        "package-discipline",
        "repository-policy",
        "sdfii-symbols",
        "wiring",
    };
    const held_native_expected = [_][]const u8{
        "gate",
        "licenses",
        "package-discipline",
        "repository-policy",
        "sdfii-symbols",
        "style",
        "wiring",
    };
    const chic_expected = [_][]const u8{"chic-fmt"};
    try expectHookTools(hookTools(.native, false), &public_native_expected);
    try expectHookTools(hookTools(.native, true), &held_native_expected);
    try expectHookTools(hookTools(.chic, false), &chic_expected);
    try expectHookTools(hookTools(.chic, true), &chic_expected);
}

fn expectHookTools(active: []const Tool, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, active.len);
    for (active, expected) |tool, name| {
        try std.testing.expectEqualStrings(name, tool.name);
    }
}

pub fn refreshTool(name: []const u8) ?[]const u8 {
    for (all_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool.name;
        for (tool.runtime_artifacts) |artifact| {
            if (std.mem.eql(u8, artifact, name)) return tool.name;
        }
    }
    return null;
}

pub fn runtimeArtifacts(name: []const u8) []const []const u8 {
    for (all_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool.runtime_artifacts;
    }
    return &.{};
}

pub fn refreshGroup(tool: Tool, storage: *[artifact_count_max]Tool) []const Tool {
    storage[0] = tool;
    var count: usize = 1;
    for (tool.runtime_artifacts) |name| {
        std.debug.assert(count < storage.len);
        storage[count] = runtimeArtifact(name);
        count += 1;
    }
    return storage[0..count];
}

pub const RefreshSetError = error{
    EmptyRefreshTool,
    UnknownRefreshTool,
    DuplicateRefreshTool,
    SeparateRefreshTool,
};

/// Resolves a comma-separated tool list into one publication cohort of active
/// tools. The controller publishes with the binary it installs, so a tool
/// with runtime artifacts keeps its own refresh step.
pub fn refreshSet(
    active: []const Tool,
    names: []const u8,
    storage: *[tool_count_max]Tool,
) RefreshSetError![]const Tool {
    std.debug.assert(active.len <= storage.len);
    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, names, ',');
    while (entries.next()) |name| {
        if (name.len == 0) return error.EmptyRefreshTool;
        const tool = for (active) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) break candidate;
        } else return error.UnknownRefreshTool;
        if (tool.runtime_artifacts.len != 0) return error.SeparateRefreshTool;
        for (storage[0..count]) |selected| {
            if (std.mem.eql(u8, selected.name, name)) return error.DuplicateRefreshTool;
        }
        std.debug.assert(count < storage.len);
        storage[count] = tool;
        count += 1;
    }
    std.debug.assert(count > 0);
    return storage[0..count];
}

test "refresh sets resolve active tools into one cohort" {
    var storage: [tool_count_max]Tool = undefined;
    const set = try refreshSet(&public_tools, "tiny,issue,gate", &storage);
    try std.testing.expectEqual(@as(usize, 3), set.len);
    try std.testing.expectEqualStrings("tiny", set[0].name);
    try std.testing.expectEqualStrings("issue", set[1].name);
    try std.testing.expectEqualStrings("gate", set[2].name);
    var groups: InstallGroupStorage = .{};
    const split = installGroups(set, &groups);
    try std.testing.expectEqual(@as(usize, 2), split.len);
    try std.testing.expectEqual(std.builtin.OptimizeMode.fast, split[0].mode);
    try std.testing.expectEqual(@as(usize, 2), split[0].steps.len);
    try std.testing.expectEqualStrings("gate-tool", split[1].steps[0]);
}

test "refresh sets refuse loom, unknown, held, duplicate and empty names" {
    var storage: [tool_count_max]Tool = undefined;
    try std.testing.expectError(
        error.SeparateRefreshTool,
        refreshSet(&all_tools, "tiny,loom", &storage),
    );
    try std.testing.expectError(
        error.UnknownRefreshTool,
        refreshSet(&all_tools, "tiny,unknown", &storage),
    );
    try std.testing.expectError(
        error.UnknownRefreshTool,
        refreshSet(&public_tools, "style", &storage),
    );
    try std.testing.expectError(
        error.DuplicateRefreshTool,
        refreshSet(&all_tools, "tiny,tiny", &storage),
    );
    try std.testing.expectError(error.EmptyRefreshTool, refreshSet(&all_tools, "", &storage));
    try std.testing.expectError(
        error.EmptyRefreshTool,
        refreshSet(&all_tools, "tiny,", &storage),
    );
}

test "refresh sets accept every active tool but loom at once" {
    var names: [tool_count_max * 32]u8 = undefined;
    var length: usize = 0;
    for (all_tools) |tool| {
        if (tool.runtime_artifacts.len != 0) continue;
        if (length != 0) {
            names[length] = ',';
            length += 1;
        }
        @memcpy(names[length..][0..tool.name.len], tool.name);
        length += tool.name.len;
    }
    var storage: [tool_count_max]Tool = undefined;
    const set = try refreshSet(&all_tools, names[0..length], &storage);
    try std.testing.expectEqual(all_tools.len - 1, set.len);
}

fn runtimeArtifact(name: []const u8) Tool {
    for (loom_companion_tools) |artifact| {
        if (std.mem.eql(u8, artifact.name, name)) return artifact;
    }
    std.debug.panic("runtime artifact {s} has no catalog entry", .{name});
}

pub const artifact_count_max = tool_count_max + loom_companion_tools.len;

pub const InstallGroup = struct {
    mode: std.builtin.OptimizeMode,
    steps: []const []const u8,
};

pub const InstallGroupStorage = struct {
    groups: [4]InstallGroup = undefined,
    steps: [4][artifact_count_max][]const u8 = undefined,
};

pub fn installGroups(
    selected_tools: []const Tool,
    storage: *InstallGroupStorage,
) []const InstallGroup {
    std.debug.assert(selected_tools.len > 0);
    std.debug.assert(selected_tools.len <= artifact_count_max);
    const modes = [_]std.builtin.OptimizeMode{ .fast, .small, .safe, .debug };
    var group_count: usize = 0;
    for (modes) |mode| {
        var step_count: usize = 0;
        for (selected_tools) |tool| {
            if ((tool.install_optimize orelse .fast) != mode) continue;
            var duplicate = false;
            for (storage.steps[group_count][0..step_count]) |step| {
                if (std.mem.eql(u8, step, tool.build_step)) duplicate = true;
            }
            if (duplicate) continue;
            storage.steps[group_count][step_count] = tool.build_step;
            step_count += 1;
        }
        if (step_count == 0) continue;
        storage.groups[group_count] = .{
            .mode = mode,
            .steps = storage.steps[group_count][0..step_count],
        };
        group_count += 1;
    }
    return storage.groups[0..group_count];
}

test "install groups split mixed hooks and keep one-mode refresh singular" {
    var storage: InstallGroupStorage = .{};
    const mixed = installGroups(hookTools(.native, false), &storage);
    try std.testing.expectEqual(@as(usize, 2), mixed.len);
    try std.testing.expectEqual(std.builtin.OptimizeMode.fast, mixed[0].mode);
    try std.testing.expectEqual(std.builtin.OptimizeMode.small, mixed[1].mode);
    try std.testing.expectEqualStrings("licenses-tool", mixed[0].steps[0]);
    try std.testing.expectEqual(@as(usize, 4), mixed[0].steps.len);
    try std.testing.expectEqualStrings("gate-tool", mixed[1].steps[0]);
    try std.testing.expectEqual(@as(usize, 1), mixed[1].steps.len);

    const single = installGroups(&.{gate_tool}, &storage);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqual(std.builtin.OptimizeMode.small, single[0].mode);
    try std.testing.expectEqualStrings("gate-tool", single[0].steps[0]);
}

test "catalog refresh owners cover every registered artifact" {
    for (all_tools) |tool| {
        var storage: [artifact_count_max]Tool = undefined;
        const group = refreshGroup(tool, &storage);
        for (group) |artifact| {
            try std.testing.expectEqualStrings(tool.name, refreshTool(artifact.name).?);
            try std.testing.expectEqualStrings(tool.build_step, artifact.build_step);
        }
    }
    try std.testing.expectEqual(@as(?[]const u8, null), refreshTool("unknown-tool"));
}

test "runtime artifact declarations stay within their publication cohort" {
    try std.testing.expectEqual(loom_companion_tools.len, runtimeArtifacts("loom").len);
    for (all_tools) |tool| {
        var storage: [artifact_count_max]Tool = undefined;
        const group = refreshGroup(tool, &storage);
        for (runtimeArtifacts(tool.name)) |name| {
            var found = false;
            for (group) |artifact| {
                if (!std.mem.eql(u8, artifact.name, name)) continue;
                try std.testing.expect(!std.mem.eql(u8, name, tool.name));
                try std.testing.expectEqual(@as(usize, 0), artifact.runtime_artifacts.len);
                found = true;
            }
            try std.testing.expect(found);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), runtimeArtifacts("unknown").len);
    try std.testing.expectEqual(@as(usize, 0), runtimeArtifacts("wiring").len);
}
