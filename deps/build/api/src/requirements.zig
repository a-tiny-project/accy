//! Versioned execution requirements shared by build catalogs and executors.

const std = @import("std");
pub const capacity = @import("capacity.zig");

pub const version: u16 = 7;
// Leave bounded room above the 1,025 lanes observed when the Choir closure
// joined the graph, without changing the separate edit catalog.
pub const lane_capacity: usize = 1152;
pub const step_bytes_max: usize = 128;
pub const directory_bytes_max: usize = 256;

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

    pub fn valid(requirement: Requirement) bool {
        return requirement.memory_mib > 0 and requirement.cpu_jobs > 0 and
            (requirement.memory_bytes == null or requirement.memory_bytes.? > 0) and
            requirement.evidence_ref.len > 0 and requirement.evidence_ref.len <= 512 and
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
        var catalog: Catalog = .{};
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        while (true) {
            const token = try source.nextAlloc(allocator, options.allocate.?);
            const step = switch (token) {
                inline .string, .allocated_string => |value| value,
                .object_end => break,
                else => return error.UnexpectedToken,
            };
            if (catalog.containsStep(step)) return error.DuplicateField;
            try parseGroup(&catalog, step, allocator, source, options);
        }
        return catalog;
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
        const Wire = struct {
            schema_version: u16,
            requirements: Catalog,
        };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        if (wire.schema_version != version or wire.requirements.count == 0) {
            return error.UnexpectedToken;
        }
        return .{
            .schema_version = wire.schema_version,
            .requirements = wire.requirements,
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
        const wire = try std.json.innerParse(WireLane, allocator, source, options);
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
