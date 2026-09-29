const std = @import("std");

pub const Targets = struct {
    product: std.Build.ResolvedTarget,
    host: std.Build.ResolvedTarget,

    pub fn rolesCoincide(targets: Targets) bool {
        return eql(targets.product, targets.host);
    }
};

pub fn standardTargets(b: *std.Build) Targets {
    return .{
        .product = b.standardTargetOptions(.{}),
        .host = b.graph.host,
    };
}

pub fn eql(
    left: std.Build.ResolvedTarget,
    right: std.Build.ResolvedTarget,
) bool {
    const left_target = left.result;
    const right_target = right.result;
    if (left_target.cpu.arch != right_target.cpu.arch) return false;
    if (left_target.cpu.model != right_target.cpu.model) return false;
    if (!left_target.cpu.features.eql(right_target.cpu.features)) return false;
    if (left_target.os.tag != right_target.os.tag) return false;
    if (left_target.abi != right_target.abi) return false;
    if (!osVersionEqual(left_target, right_target)) return false;
    if (left_target.ofmt != right_target.ofmt) return false;
    return left_target.dynamic_linker.eql(right_target.dynamic_linker);
}

fn osVersionEqual(left: std.Target, right: std.Target) bool {
    std.debug.assert(left.os.tag == right.os.tag);
    std.debug.assert(left.abi == right.abi);
    return switch (left.os.tag.versionRangeTag()) {
        .none => true,
        .semver => versionRangeEqual(
            left.os.version_range.semver,
            right.os.version_range.semver,
        ),
        .hurd => versionRangeEqual(
            left.os.version_range.hurd.range,
            right.os.version_range.hurd.range,
        ) and (!left.abi.isGnu() or versionEqual(
            left.os.version_range.hurd.glibc,
            right.os.version_range.hurd.glibc,
        )),
        .linux => versionRangeEqual(
            left.os.version_range.linux.range,
            right.os.version_range.linux.range,
        ) and (!left.abi.isGnu() or versionEqual(
            left.os.version_range.linux.glibc,
            right.os.version_range.linux.glibc,
        )) and (!left.abi.isAndroid() or
            left.os.version_range.linux.android ==
                right.os.version_range.linux.android),
        .windows => left.os.version_range.windows.min ==
            right.os.version_range.windows.min and
            left.os.version_range.windows.max ==
                right.os.version_range.windows.max,
    };
}

fn versionRangeEqual(
    left: std.SemanticVersion.Range,
    right: std.SemanticVersion.Range,
) bool {
    return versionEqual(left.min, right.min) and
        versionEqual(left.max, right.max);
}

fn versionEqual(
    left: std.SemanticVersion,
    right: std.SemanticVersion,
) bool {
    return left.order(right) == .eq;
}

pub fn query(target: std.Build.ResolvedTarget) std.Target.Query {
    var resolved = std.Target.Query.fromTarget(&target.result);
    resolved.ofmt = target.result.ofmt;
    resolved.dynamic_linker = target.result.dynamic_linker;
    return resolved;
}

pub fn runnableBaselineQuery(
    fallback: std.Build.ResolvedTarget,
    explicit: ?[]const u8,
) !std.Target.Query {
    if (explicit) |value| {
        return std.Target.Query.parse(.{
            .arch_os_abi = value,
            .cpu_features = "baseline",
        });
    }
    var resolved = query(fallback);
    resolved.cpu_model = .baseline;
    resolved.cpu_features_add = .empty;
    resolved.cpu_features_sub = .empty;
    resolved.os_version_min = null;
    resolved.os_version_max = null;
    std.debug.assert(resolved.cpu_arch != null);
    std.debug.assert(resolved.os_tag != null);
    const architecture = resolved.cpu_arch.?;
    const operating_system = resolved.os_tag.?;
    if (resolved.abi == std.Target.Abi.default(architecture, operating_system)) {
        resolved.abi = null;
    }
    return resolved;
}

test "runnable baseline target queries omit detected host ranges" {
    const Case = struct {
        detected: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .detected = "x86_64-linux.7.0.11...7.0.11-gnu.2.42",
            .expected = "x86_64-linux-gnu.2.42",
        },
        .{
            .detected = "aarch64-macos.15.0...15.0",
            .expected = "aarch64-macos",
        },
    };
    for (cases) |case| {
        const detected = try std.Target.Query.parse(.{
            .arch_os_abi = case.detected,
            .cpu_features = "baseline",
        });
        const fallback = std.Build.ResolvedTarget{
            .query = detected,
            .result = try std.zig.system.resolveTargetQuery(
                std.testing.io,
                detected,
            ),
        };
        const canonical = try runnableBaselineQuery(fallback, null);
        const triple = try canonical.zigTriple(std.testing.allocator);
        defer std.testing.allocator.free(triple);
        try std.testing.expectEqualStrings(case.expected, triple);
        try std.testing.expectEqual(
            std.Target.Query.CpuModel.baseline,
            canonical.cpu_model,
        );
        try std.testing.expectEqual(fallback.result.ofmt, canonical.ofmt.?);
        try std.testing.expect(fallback.result.dynamic_linker.eql(
            canonical.dynamic_linker.?,
        ));
        try std.testing.expect(canonical.cpu_features_add.isEmpty());
        try std.testing.expect(canonical.cpu_features_sub.isEmpty());
        try std.testing.expectEqual(null, canonical.os_version_min);
        try std.testing.expectEqual(null, canonical.os_version_max);
    }
}

test "runnable baseline target queries preserve explicit overrides" {
    const detected = try std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu.2.42",
    });
    const fallback = std.Build.ResolvedTarget{
        .query = detected,
        .result = try std.zig.system.resolveTargetQuery(std.testing.io, detected),
    };
    const expected = "aarch64-linux.6.1...6.6-gnu.2.39";
    const explicit = try runnableBaselineQuery(fallback, expected);
    const triple = try explicit.zigTriple(std.testing.allocator);
    defer std.testing.allocator.free(triple);
    try std.testing.expectEqualStrings(expected, triple);
    try std.testing.expectEqual(
        std.Target.Query.CpuModel.baseline,
        explicit.cpu_model,
    );
    try std.testing.expect(explicit.os_version_min != null);
    try std.testing.expect(explicit.os_version_max != null);
}

test "resolved target equality matches canonical query equality" {
    const Query = std.Target.Query;
    var queries = [_]Query{
        try Query.parse(.{ .arch_os_abi = "x86_64-linux-gnu" }),
        try Query.parse(.{ .arch_os_abi = "x86_64-linux-musl" }),
        try Query.parse(.{ .arch_os_abi = "aarch64-linux-gnu" }),
        try Query.parse(.{ .arch_os_abi = "wasm32-freestanding" }),
        try Query.parse(.{ .arch_os_abi = "x86_64-windows-msvc" }),
        try Query.parse(.{ .arch_os_abi = "x86_64-macos" }),
        try Query.parse(.{ .arch_os_abi = "x86_64-linux-gnu" }),
    };
    queries[queries.len - 1].ofmt = .elf;

    var targets: [queries.len]std.Build.ResolvedTarget = undefined;
    for (queries, &targets) |target_query, *target| {
        target.* = .{
            .query = target_query,
            .result = try std.zig.system.resolveTargetQuery(
                std.testing.io,
                target_query,
            ),
        };
    }
    for (targets) |left| {
        for (targets) |right| {
            try std.testing.expectEqual(
                query(left).eql(query(right)),
                eql(left, right),
            );
        }
    }

    var left = targets[0];
    var right = targets[0];
    left.result.os.version_range.linux.range.min.build = "left";
    right.result.os.version_range.linux.range.min.build = "right";
    try std.testing.expect(query(left).eql(query(right)));
    try std.testing.expect(eql(left, right));
}
