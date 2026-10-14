//! Versioned execution requirements shared by build catalogs and executors.

const std = @import("std");
pub const capacity = @import("capacity.zig");

pub const version: u16 = 7;
// The catalog holds one lane per generated edit lane and execution lane: 763
// and 391 at 19a7f00a40, 1,154 together, where a registry check with root
// visibility costs one execution lane. Two bounds meet here. The count must
// fit, and the manifest parser returns the catalog by value, so the catalog's
// size is held by the four MiB caller stack witness below: 1,408 lanes pass
// it and 1,472 overflow. 1,344 keeps one 64-lane step under the last passing
// figure. That leaves 190 lanes, which is short on purpose until the catalog
// leaves the stack.
pub const lane_capacity: usize = 1344;
pub const step_bytes_max: usize = 128;
pub const directory_bytes_max: usize = 256;
pub const evidence_ref_bytes_max: usize = 512;

const mebibyte: u64 = 1024 * 1024;

pub const ResourceClass = enum {
    ordinary,
    heavy,
};

/// Where automatic placement may run a lane. `site` lets a site run it when
/// this host lacks room. `site_first` sends it to a matching site even when
/// this host has room, and runs it here only when no site matches.
pub const Placement = enum {
    local,
    site,
    site_first,
};

pub const Repository = enum {
    snapshot,
    history,
};

pub const PlatformOs = enum {
    host,
    linux,
    macos,
    windows,
    freebsd,
    netbsd,
    openbsd,
};

pub const PlatformArchitecture = enum {
    host,
    aarch64,
    x86_64,
};

pub const Executable = enum(u8) {
    zig,
    lean,
    lake,
    z3,
    node,

    pub fn text(executable: Executable) []const u8 {
        return @tagName(executable);
    }
};

pub const executable_values = std.meta.tags(Executable).*;
pub const executable_capacity: usize = executable_values.len;
pub const ExecutablesInitError = error{
    DuplicateExecutable,
    TooManyExecutables,
};

pub const Executables = struct {
    included: [executable_capacity]bool = @splat(false),

    pub fn init(values: []const Executable) ExecutablesInitError!Executables {
        if (values.len > executable_capacity) return error.TooManyExecutables;
        var result: Executables = .{};
        for (values) |value| {
            if (result.contains(value)) return error.DuplicateExecutable;
            result.include(value);
        }
        return result;
    }

    pub fn include(executables: *Executables, executable: Executable) void {
        const index: usize = @backingInt(executable);
        std.debug.assert(index < executables.included.len);
        executables.included[index] = true;
    }

    pub fn merge(executables: *Executables, other: Executables) void {
        for (&executables.included, other.included) |*included, candidate| {
            included.* = included.* or candidate;
        }
    }

    pub fn contains(executables: Executables, executable: Executable) bool {
        const index: usize = @backingInt(executable);
        std.debug.assert(index < executables.included.len);
        return executables.included[index];
    }

    pub fn count(executables: Executables) usize {
        var result: usize = 0;
        for (executables.included) |included| result += @intFromBool(included);
        return result;
    }

    pub fn jsonStringify(executables: Executables, writer: anytype) !void {
        try writer.beginArray();
        inline for (executable_values) |executable| {
            if (executables.contains(executable)) try writer.write(executable.text());
        }
        try writer.endArray();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Executables {
        if (.array_begin != try source.next()) return error.UnexpectedToken;
        var result: Executables = .{};
        var parsed_count: usize = 0;
        while (try source.peekNextTokenType() != .array_end) {
            if (parsed_count == executable_capacity) return error.Overflow;
            const token = try source.nextAlloc(allocator, options.allocate.?);
            const text = switch (token) {
                inline .string, .allocated_string => |value| value,
                else => return error.UnexpectedToken,
            };
            const executable = std.meta.stringToEnum(Executable, text) orelse
                return error.UnexpectedToken;
            if (result.contains(executable)) return error.DuplicateField;
            result.include(executable);
            parsed_count += 1;
        }
        _ = try source.next();
        return result;
    }
};

pub const Platform = struct {
    os: PlatformOs,
    architecture: PlatformArchitecture,

    pub const host = Platform{
        .os = .host,
        .architecture = .host,
    };
};

pub const EvidenceKind = enum { measured, exploratory, defaulted };

pub const Requirement = struct {
    class: ResourceClass,
    placement: Placement,
    repository: Repository = .snapshot,
    memory_mib: u32,
    memory_bytes: ?u64 = null,
    cpu_jobs: u16,
    evidence_kind: EvidenceKind = .defaulted,
    evidence_ref: []const u8 = capacity.default_evidence_ref,
    executables: Executables = .{},
    platform: Platform,
    /// The lane writes the source tree, so it runs where the source lives: a
    /// site would take the writes into its own copy and leave the caller's
    /// tree without them. Such a lane is placed locally.
    writes_source: bool = false,

    pub fn valid(requirement: Requirement) bool {
        return requirement.memory_mib > 0 and requirement.cpu_jobs > 0 and
            (!requirement.writes_source or requirement.placement == .local) and
            (requirement.memory_bytes == null or requirement.memory_bytes.? > 0) and
            requirement.evidence_ref.len > 0 and
            requirement.evidence_ref.len <= evidence_ref_bytes_max and
            std.mem.indexOfAny(u8, requirement.evidence_ref, "\t\r\n") == null;
    }
};

pub fn defaultRequirement(class: ResourceClass) Requirement {
    return .{
        .class = class,
        .placement = switch (class) {
            .ordinary => .local,
            .heavy => .site,
        },
        .repository = .snapshot,
        .memory_mib = @intCast(switch (class) {
            .ordinary => capacity.ordinary.process_memory_claim,
            .heavy => capacity.heavy.process_memory_claim,
        } / mebibyte),
        .cpu_jobs = @intCast(capacity.buildCpuClaim()),
        .platform = .host,
    };
}

/// Declares a sampled tree claim while preserving ordinary lane policy.
pub fn measuredRequirement(memory_mib: u32, evidence_ref: []const u8) Requirement {
    var requirement = defaultRequirement(.ordinary);
    requirement.memory_mib = memory_mib;
    requirement.evidence_kind = .measured;
    requirement.evidence_ref = evidence_ref;
    std.debug.assert(requirement.valid());
    return requirement;
}

/// Local receipts over 14 days to 2026-10-06: p99 700,356 KiB and sample
/// maximum 756,928 KiB. Claim 1.5x the larger peak, rounded up to 512 MiB.
/// The manifest bootstrap and the registered step share this declaration.
pub const package_catalog_requirement = measuredRequirement(1536, "build/api/src/requirements.zig");

/// The ordinary requirement for a lane without manifest evidence: a step the
/// manifest omits, or a manifest that cannot be read. Nothing says such a lane
/// fits the default, so it claims the fallback.
pub fn fallbackRequirement() Requirement {
    var requirement = defaultRequirement(.ordinary);
    requirement.memory_mib = @intCast(capacity.fallback_memory_bytes / mebibyte);
    std.debug.assert(requirement.valid());
    return requirement;
}

pub const Lane = struct {
    step: []const u8,
    directory: []const u8,
    requirement: Requirement,
    /// One alternative for a recognized focused invocation; broad remains the default.
    focused_requirement: ?*const Requirement = null,
    promoted_test_filters: bool = false,
};

pub const FocusedError = error{
    MissingLane,
    DuplicateFocusedRequirement,
    InvalidRequirement,
    PlatformMismatch,
    OutOfMemory,
};

pub const Catalog = struct {
    values: [lane_capacity]Lane = undefined,
    count: u16 = 0,

    pub const AddError = error{
        DuplicateLane,
        InvalidDirectory,
        InvalidRequirement,
        InvalidStep,
        TooManyLanes,
    };

    pub fn add(
        catalog: *Catalog,
        step: []const u8,
        directory: []const u8,
        requirement: Requirement,
    ) AddError!void {
        if (!validIdentity(step, step_bytes_max)) return error.InvalidStep;
        if (!validIdentity(directory, directory_bytes_max)) {
            return error.InvalidDirectory;
        }
        if (!requirement.valid()) return error.InvalidRequirement;
        if (catalog.get(step, directory) != null) return error.DuplicateLane;
        if (catalog.count == lane_capacity) return error.TooManyLanes;
        catalog.values[catalog.count] = .{
            .step = step,
            .directory = directory,
            .requirement = requirement,
        };
        catalog.count += 1;
    }

    /// The allocator owns the focused record for at least the catalog lifetime.
    /// Configuration creates at most one payload per lane before admission.
    pub fn addFocused(
        catalog: *Catalog,
        allocator: std.mem.Allocator,
        step: []const u8,
        directory: []const u8,
        requirement: Requirement,
        promoted_test_filters: bool,
    ) FocusedError!void {
        if (!requirement.valid()) return error.InvalidRequirement;
        for (catalog.values[0..catalog.count]) |*lane| {
            if (!std.mem.eql(u8, lane.step, step) or
                !std.mem.eql(u8, lane.directory, directory)) continue;
            if (lane.focused_requirement != null) return error.DuplicateFocusedRequirement;
            if (!std.meta.eql(lane.requirement.platform, requirement.platform)) {
                return error.PlatformMismatch;
            }
            std.debug.assert(lane.focused_requirement == null);
            const focused = try allocator.create(Requirement);
            focused.* = requirement;
            lane.focused_requirement = focused;
            lane.promoted_test_filters = promoted_test_filters;
            return;
        }
        return error.MissingLane;
    }

    pub fn get(
        catalog: *const Catalog,
        step: []const u8,
        directory: []const u8,
    ) ?Lane {
        for (catalog.items()) |lane| {
            if (std.mem.eql(u8, lane.step, step) and
                std.mem.eql(u8, lane.directory, directory))
            {
                return lane;
            }
        }
        return null;
    }

    pub fn items(catalog: *const Catalog) []const Lane {
        return catalog.values[0..catalog.count];
    }

    pub fn jsonStringify(catalog: Catalog, writer: anytype) !void {
        try writer.beginObject();
        for (catalog.items(), 0..) |lane, index| {
            if (stepAppearsBefore(catalog.items(), index)) continue;
            try writer.objectField(lane.step);
            try writer.beginArray();
            for (catalog.items()) |candidate| {
                if (!std.mem.eql(u8, candidate.step, lane.step)) continue;
                try writer.write(WireLane.from(candidate));
            }
            try writer.endArray();
        }
        try writer.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Catalog {
        const catalog = try allocator.create(Catalog);
        defer allocator.destroy(catalog);
        catalog.count = 0;
        try catalog.parseInto(allocator, source, options);
        return catalog.*;
    }

    fn parseInto(
        catalog: *Catalog,
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!void {
        std.debug.assert(catalog.count == 0);
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        while (true) {
            const token = try source.nextAlloc(allocator, options.allocate.?);
            const step = switch (token) {
                inline .string, .allocated_string => |value| value,
                .object_end => break,
                else => return error.UnexpectedToken,
            };
            if (catalog.containsStep(step)) return error.DuplicateField;
            try parseGroup(catalog, step, allocator, source, options);
        }
    }

    fn containsStep(catalog: *const Catalog, step: []const u8) bool {
        for (catalog.items()) |lane| {
            if (std.mem.eql(u8, lane.step, step)) return true;
        }
        return false;
    }
};

pub const Manifest = struct {
    schema_version: u16,
    requirements: Catalog,

    pub fn init(requirements: Catalog) Manifest {
        std.debug.assert(requirements.count > 0);
        return .{
            .schema_version = version,
            .requirements = requirements,
        };
    }

    pub fn jsonStringify(manifest: Manifest, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("schema_version");
        try writer.write(manifest.schema_version);
        try writer.objectField("requirements");
        try writer.write(manifest.requirements);
        try writer.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Manifest {
        // Parsing is configuration-time. One bounded scratch catalog avoids
        // full-capacity Wire and Catalog temporaries on nested caller stacks.
        const catalog = try allocator.create(Catalog);
        defer allocator.destroy(catalog);
        catalog.count = 0;
        var schema_version: ?u16 = null;
        var requirements_seen = false;
        var compatible_options = options;
        compatible_options.ignore_unknown_fields = true;
        compatible_options.duplicate_field_behavior = .@"error";
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        while (true) {
            const token = try source.nextAlloc(allocator, options.allocate.?);
            const name = switch (token) {
                inline .string, .allocated_string => |value| value,
                .object_end => break,
                else => return error.UnexpectedToken,
            };
            if (std.mem.eql(u8, name, "schema_version")) {
                if (schema_version != null) return error.DuplicateField;
                schema_version = try std.json.innerParse(
                    u16,
                    allocator,
                    source,
                    compatible_options,
                );
            } else if (std.mem.eql(u8, name, "requirements")) {
                if (requirements_seen) return error.DuplicateField;
                requirements_seen = true;
                try catalog.parseInto(allocator, source, compatible_options);
            } else {
                try source.skipValue();
            }
        }
        if (schema_version == null or !requirements_seen) return error.MissingField;
        if (schema_version.? != version or catalog.count == 0) {
            return error.UnexpectedToken;
        }
        return .{
            .schema_version = schema_version.?,
            .requirements = catalog.*,
        };
    }
};

const WireLane = struct {
    directory: []const u8,
    class: ResourceClass,
    placement: Placement,
    repository: Repository,
    memory_mib: u32,
    memory_bytes: ?u64 = null,
    cpu_jobs: u16,
    evidence_kind: EvidenceKind = .defaulted,
    evidence_ref: []const u8 = capacity.default_evidence_ref,
    executables: Executables,
    platform: Platform,
    focused_requirement: ?Requirement = null,
    promoted_test_filters: bool = false,
    writes_source: bool = false,

    pub fn jsonStringify(lane: WireLane, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(WireLane).@"struct".field_names) |field_name| {
            // Reader publication precedes focused declarations. Until then,
            // default lanes emit the previous wire shape for existing users.
            const emit = if (comptime std.mem.eql(u8, field_name, "focused_requirement"))
                lane.focused_requirement != null
            else if (comptime std.mem.eql(u8, field_name, "promoted_test_filters"))
                lane.promoted_test_filters
            else if (comptime std.mem.eql(u8, field_name, "writes_source"))
                lane.writes_source
            else
                true;
            if (emit) {
                try writer.objectField(field_name);
                try writer.write(@field(lane, field_name));
            }
        }
        try writer.endObject();
    }

    fn from(lane: Lane) WireLane {
        return .{
            .directory = lane.directory,
            .class = lane.requirement.class,
            .placement = lane.requirement.placement,
            .repository = lane.requirement.repository,
            .memory_mib = lane.requirement.memory_mib,
            .memory_bytes = lane.requirement.memory_bytes,
            .cpu_jobs = lane.requirement.cpu_jobs,
            .evidence_kind = lane.requirement.evidence_kind,
            .evidence_ref = lane.requirement.evidence_ref,
            .executables = lane.requirement.executables,
            .platform = lane.requirement.platform,
            .focused_requirement = if (lane.focused_requirement) |focused| focused.* else null,
            .promoted_test_filters = lane.promoted_test_filters,
            .writes_source = lane.requirement.writes_source,
        };
    }

    fn requirement(wire: WireLane) Requirement {
        return .{
            .class = wire.class,
            .placement = wire.placement,
            .repository = wire.repository,
            .memory_mib = wire.memory_mib,
            .memory_bytes = wire.memory_bytes,
            .cpu_jobs = wire.cpu_jobs,
            .evidence_kind = wire.evidence_kind,
            .evidence_ref = wire.evidence_ref,
            .executables = wire.executables,
            .platform = wire.platform,
            .writes_source = wire.writes_source,
        };
    }
};

fn parseGroup(
    catalog: *Catalog,
    step: []const u8,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!void {
    if (.array_begin != try source.next()) return error.UnexpectedToken;
    var group_count: u16 = 0;
    while (try source.peekNextTokenType() != .array_end) {
        var compatible_options = options;
        compatible_options.ignore_unknown_fields = true;
        compatible_options.duplicate_field_behavior = .@"error";
        const wire = try std.json.innerParse(WireLane, allocator, source, compatible_options);
        catalog.add(step, wire.directory, wire.requirement()) catch |err| {
            return switch (err) {
                error.DuplicateLane => error.DuplicateField,
                error.TooManyLanes => error.Overflow,
                error.InvalidDirectory,
                error.InvalidRequirement,
                error.InvalidStep,
                => error.UnexpectedToken,
            };
        };
        if (wire.focused_requirement) |focused| {
            catalog.addFocused(
                allocator,
                step,
                wire.directory,
                focused,
                wire.promoted_test_filters,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.UnexpectedToken,
            };
        } else {
            catalog.values[catalog.count - 1].promoted_test_filters = wire.promoted_test_filters;
        }
        group_count += 1;
    }
    _ = try source.next();
    if (group_count == 0) return error.UnexpectedToken;
}

fn stepAppearsBefore(lanes: []const Lane, index: usize) bool {
    std.debug.assert(index < lanes.len);
    for (lanes[0..index]) |lane| {
        if (std.mem.eql(u8, lane.step, lanes[index].step)) return true;
    }
    return false;
}

fn validIdentity(value: []const u8, maximum: usize) bool {
    return value.len > 0 and value.len <= maximum and
        std.mem.indexOfAny(u8, value, "\t\r\n") == null;
}

const ordinary = defaultRequirement(.ordinary);

const OldWireLane = struct {
    directory: []const u8,
    class: ResourceClass,
    placement: Placement,
    repository: Repository,
    memory_mib: u32,
    cpu_jobs: u16,
    platform: Platform,
};
const OldWireManifest = struct {
    schema_version: u16,
    requirements: struct { @"test": []const OldWireLane },
};

fn parseManifestOnBoundedStack(failure: *?anyerror) void {
    parseBoundedManifest() catch |err| {
        failure.* = err;
    };
}

fn parseBoundedManifest() !void {
    const bytes = "{\"schema_version\":7,\"requirements\":{\"test\":[{" ++
        "\"directory\":\"lib/research/chic\",\"class\":\"ordinary\"," ++
        "\"placement\":\"site_first\",\"repository\":\"snapshot\"," ++
        "\"memory_mib\":3584,\"cpu_jobs\":4,\"executables\":[]," ++
        "\"platform\":{\"os\":\"host\",\"architecture\":\"host\"}," ++
        "\"focused_requirement\":null,\"promoted_test_filters\":true}]}}";
    const parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const lane = parsed.value.requirements.get("test", "lib/research/chic").?;
    try std.testing.expectEqual(@as(u32, 3584), lane.requirement.memory_mib);
    try std.testing.expect(lane.promoted_test_filters);
}
