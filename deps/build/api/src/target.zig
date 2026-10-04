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
