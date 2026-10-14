const std = @import("std");
const alloc_phase = @import("alloc_phase");

const capacity = alloc_phase.capacity;

/// Identifies which container a font file uses, among TrueType, OpenType, the
/// two collection containers, and Type 1, so a caller tells a TrueType file
/// from a Type 1 file. The answer comes from the text after the last dot in the
/// name, and no file gets opened to reach it.
pub const Format = enum(u8) {
    truetype,
    opentype,
    truetype_collection,
    opentype_collection,
    type1,

    /// Decides whether a file is a font at all by reading the text after a
    /// name's last dot and matching it against the known extensions, upper and
    /// lower case alike. The matched extensions are ttf, otf, ttc, otc, and
    /// pfb, while a name with no dot, an empty extension, or an extension
    /// longer than `extension_bytes_max` returns null.
    pub fn fromName(name: []const u8) ?Format {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        const extension = name[dot + 1 ..];
        if (extension.len == 0 or extension.len > extension_bytes_max) return null;
        var lowered: [extension_bytes_max]u8 = undefined;
        for (extension, 0..) |byte, index| lowered[index] = std.ascii.toLower(byte);
        const folded = lowered[0..extension.len];
        if (std.mem.eql(u8, folded, "ttf")) return .truetype;
        if (std.mem.eql(u8, folded, "otf")) return .opentype;
        if (std.mem.eql(u8, folded, "ttc")) return .truetype_collection;
        if (std.mem.eql(u8, folded, "otc")) return .opentype_collection;
        if (std.mem.eql(u8, folded, "pfb")) return .type1;
        return null;
    }
};

/// Records one accepted font file so a caller walking admitted entries can get
/// each font's path and size. The record keeps where its path sits in the path
/// arena and how long it is, the file size, the format, and which root it came
/// from. The size and the format come from one stat call, so the file itself
/// stays closed, and `Catalog.entryPath` turns the offset and length back into
/// the path bytes.
pub const Entry = extern struct {
    size_bytes: u64,
    path_offset: u32,
    path_len: u16,
    format: Format,
    root: u8,
};

/// Records one visited directory so the walk can descend from it and detect a
/// cycle. The record stores where its path sits in the path arena, its inode,
/// the record it was reached from, how deep it sits, and which root it came
/// from. The walk's cycle guard compares the inode against every ancestor's
/// inode by following the parent index, and a root's parent index is its own
/// index, which ends that climb.
pub const Directory = extern struct {
    inode: u64,
    path_offset: u32,
    parent: u32,
    path_len: u16,
    depth: u8,
    root: u8,
};

/// The longest extension `Format.fromName` will case-fold before matching, at
/// eight bytes. A longer extension is no extension.
pub const extension_bytes_max: usize = 8;

/// The ceilings on the three counts a caller picks as limits: files,
/// directories, and path bytes. A limit past any of the three is refused with
/// `CapacityExceeded`.
pub const entries_max: usize = 1 << 20;
pub const directories_max: usize = 1 << 16;
pub const path_bytes_max: usize = 1 << 26;

/// Defines the longest path the catalog will take, which lets a record hold its
/// length in sixteen bits. A longer path is refused with
/// `FontPathBytesExhausted`.
pub const path_bytes_limit: usize = std.math.maxInt(u16);

/// Specifies how large one enumeration may get through the three numbers a
/// caller picks: how many files, how many directories, and how many bytes of
/// path text.
pub const Limits = struct {
    entries: usize,
    directories: usize,
    path_bytes: usize,
};

/// Identifies which count was wrong when deriving a capacity, covering the
/// three ways a limits value fails to resolve. A zero count gives
/// `InvalidLimit`, a count past its maximum gives `CapacityExceeded`, and a
/// byte total that overflows gives `CapacityOverflow`.
pub const CapacityError = error{
    InvalidLimit,
    CapacityExceeded,
    CapacityOverflow,
};

/// What one limits value works out to: the three record counts and the size of
/// the single byte region that holds them, so a caller learns how many bytes of
/// storage the catalog needs before it allocates them. `derive` sizes the
/// storage as the entry records, plus the directory records, plus the path
/// bytes, so a caller sizes its byte region from `storage_bytes` before it
/// calls `Catalog.init`.
pub const Capacity = struct {
    entries: usize,
    directories: usize,
    path_bytes: usize,
    storage_bytes: usize,

    pub const DeriveError: type = CapacityError;

    pub fn derive(limits: Limits) DeriveError!Capacity {
        if (limits.entries == 0) return error.InvalidLimit;
        if (limits.directories == 0) return error.InvalidLimit;
        if (limits.path_bytes == 0) return error.InvalidLimit;
        if (limits.entries > entries_max) return error.CapacityExceeded;
        if (limits.directories > directories_max) return error.CapacityExceeded;
        if (limits.path_bytes > path_bytes_max) return error.CapacityExceeded;
        const entry_bytes = try capacity.mul(usize, limits.entries, @sizeOf(Entry));
        const directory_bytes = try capacity.mul(
            usize,
            limits.directories,
            @sizeOf(Directory),
        );
        const record_bytes = try capacity.add(usize, entry_bytes, directory_bytes);
        const storage_bytes = try capacity.add(usize, record_bytes, limits.path_bytes);
        std.debug.assert(storage_bytes >= limits.path_bytes);
        return .{
            .entries = limits.entries,
            .directories = limits.directories,
            .path_bytes = limits.path_bytes,
            .storage_bytes = storage_bytes,
        };
    }
};

/// Reports which of the three declared capacities ran out:
/// `FontEntriesExhausted`, `FontDirectoriesExhausted`, and
/// `FontPathBytesExhausted`.
pub const Exhaustion = error{
    FontEntriesExhausted,
    FontDirectoriesExhausted,
    FontPathBytesExhausted,
};

/// Distinguishes a bad limit from a short region when a caller hands over
/// storage. A region smaller than the derived `storage_bytes` gives
/// `StorageTooShort`, and the capacity errors carry through.
pub const InitError = CapacityError || error{StorageTooShort};

const CatalogLimits = Limits;
const CatalogCapacity = Capacity;
const CatalogExhaustion = Exhaustion;
const CatalogInitError = InitError;

/// Holds one enumeration's results and the directories still queued for the
/// walk over a byte region the caller supplies, so a caller reads the whole
/// enumeration back out of it. That byte region holds the entry records, then
/// the directory records, then the shared path arena. Each admission tests the
/// entry count, the directory count, and the remaining path bytes before it
/// writes anything, which leaves everything accepted so far untouched when one
/// of the three refuses, so a caller may read a refusal as the answer being cut
/// short at `entryCount`. The order of use runs `init`, then `activate`, then
/// admissions, then `deinit`, which hands the caller's storage back.
pub const Catalog = struct {
    phase: capacity.Phase,
    capacity: CatalogCapacity,
    storage: Storage,
    entry_count: u32,
    directory_count: u32,
    directory_head: u32,
    path_used: u32,

    pub const storage_alignment: usize = 8;
    pub const Storage: type = []align(storage_alignment) u8;
    pub const Limits: type = CatalogLimits;
    pub const Capacity: type = CatalogCapacity;
    pub const Exhaustion: type = CatalogExhaustion;
    pub const InitError: type = CatalogInitError;

    pub const work_limits: capacity.WorkLimits = .{
        .transition_steps_max = 1,
        .cleanup_steps_per_call_max = 0,
        .cleanup_calls_at_capacity_max = 0,
    };

    pub const claim: capacity.Declaration = .{
        .source = .{
            .id = "sys.font_walk",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "caller_font_entry_records",
                        .lifetime = .transferred,
                        .detail = "caller entry records for accepted font files",
                    },
                    .{
                        .id = "caller_font_directory_records",
                        .lifetime = .transferred,
                        .detail = "caller directory records for the depth bounded frontier",
                    },
                    .{
                        .id = "caller_font_path_bytes",
                        .lifetime = .transferred,
                        .detail = "caller path arena shared by entry and directory records",
                    },
                },
                .excluded = &.{
                    "caller-owned root set, walk options, and enumeration statistics",
                    "directory handles, iterator read buffers, and kernel path state",
                    "process environment strings borrowed while default roots resolve",
                },
            },
            .capacity = .{
                .inputs = &.{
                    capacity.bindInput(CatalogLimits, "entries", "entries"),
                    capacity.bindInput(CatalogLimits, "directories", "directories"),
                    capacity.bindInput(CatalogLimits, "path_bytes", "path_bytes"),
                },
                .type_selectors = &.{
                    capacity.bindType(Entry, "entry"),
                    capacity.bindType(Directory, "directory"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .scale = .{ .node = 1, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .add = .{ .left = 3, .right = 4 } },
                    .{ .add = .{ .left = 5, .right = 2 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 6,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "an admission past entry, directory, or path capacity writes nothing",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "the walk enters directory iteration owned by the standard library",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "directory handles and iterator read buffers belong to the kernel",
                },
            },
            .work = .{ .equation = "transition_steps <= 1 and cleanup_steps == 0" },
            .obligations = &.{
                .{ .key = "sys_font_walk_capacity_model", .role = .capacity_model },
                .{ .key = "sys_font_walk_overload", .role = .overload },
                .{ .key = "sys_font_walk_work_bound", .role = .work_bound },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(storage: Storage, limits: CatalogLimits) CatalogInitError!Catalog {
        const derived = try CatalogCapacity.derive(limits);
        if (storage.len < derived.storage_bytes) return error.StorageTooShort;
        return .{
            .phase = .initialization,
            .capacity = derived,
            .storage = storage,
            .entry_count = 0,
            .directory_count = 0,
            .directory_head = 0,
            .path_used = 0,
        };
    }

    pub fn activate(self: *Catalog) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    /// Resets the catalog so a caller reuses one region for a second
    /// enumeration. The call sets the entry count, the directory count, the
    /// queue position, and the used path bytes back to zero, while the caller's
    /// storage stays with the catalog.
    pub fn reset(self: *Catalog) void {
        std.debug.assert(self.phase == .steady);
        self.entry_count = 0;
        self.directory_count = 0;
        self.directory_head = 0;
        self.path_used = 0;
    }

    /// Appends one accepted font file during the walk, taking its path, its
    /// size, its format, and the index of the root it came from. The entry
    /// count and the remaining path bytes are both checked before anything is
    /// written, so a refusal changes no record and no byte.
    pub fn appendEntry(
        self: *Catalog,
        path: []const u8,
        size_bytes: u64,
        format: Format,
        root: u8,
    ) CatalogExhaustion!void {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(path.len != 0);
        if (self.entry_count == self.capacity.entries) return error.FontEntriesExhausted;
        const offset = try self.reservePath(path);
        self.entryStore()[self.entry_count] = .{
            .size_bytes = size_bytes,
            .path_offset = offset,
            .path_len = @intCast(path.len),
            .format = format,
            .root = root,
        };
        self.entry_count += 1;
    }

    /// Puts one root directory on the queue and hands back the index of its
    /// record. The walk calls it once per font root before it starts
    /// descending. The record's parent index is its own index, which terminates
    /// the ancestor climb of the walk's cycle guard.
    pub fn appendRoot(
        self: *Catalog,
        path: []const u8,
        inode: u64,
        root: u8,
    ) CatalogExhaustion!u32 {
        const index = try self.appendDirectory(path, inode, self.directory_count, 0, root);
        std.debug.assert(self.directoryStore()[index].parent == index);
        return index;
    }

    /// Puts one subdirectory on the queue, once the walk decides to descend
    /// into it, and hands back the index of its record. The record keeps the
    /// inode, the index of the record it was reached from, how far beneath the
    /// root it sits, and which root that is. The directory count and the
    /// remaining path bytes are both checked before anything is written, so a
    /// refusal changes no record and no byte.
    pub fn appendDirectory(
        self: *Catalog,
        path: []const u8,
        inode: u64,
        parent: u32,
        depth: u8,
        root: u8,
    ) CatalogExhaustion!u32 {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(path.len != 0);
        if (self.directory_count == self.capacity.directories) {
            return error.FontDirectoriesExhausted;
        }
        const offset = try self.reservePath(path);
        std.debug.assert(self.directory_count < self.capacity.directories);
        const index = self.directory_count;
        std.debug.assert(parent <= index);
        self.directoryStore()[index] = .{
            .inode = inode,
            .path_offset = offset,
            .parent = parent,
            .path_len = @intCast(path.len),
            .depth = depth,
            .root = root,
        };
        self.directory_count += 1;
        return index;
    }

    /// Drains the frontier one directory per turn for the walk, taking the next
    /// directory off the queue and returning its index. The call returns null
    /// once the frontier is drained. Records come back in the order they went
    /// in, which makes the walk breadth-first.
    pub fn takeDirectory(self: *Catalog) ?u32 {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.directory_head <= self.directory_count);
        if (self.directory_head == self.directory_count) return null;
        const index = self.directory_head;
        self.directory_head += 1;
        return index;
    }

    pub fn directoryAt(self: *const Catalog, index: u32) Directory {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(index < self.directory_count);
        return self.directoryStore()[index];
    }

    pub fn entryCount(self: *const Catalog) u32 {
        return self.entry_count;
    }

    pub fn directoryCount(self: *const Catalog) u32 {
        return self.directory_count;
    }

    pub fn pathBytesUsed(self: *const Catalog) u32 {
        return self.path_used;
    }

    pub fn entries(self: *const Catalog) []const Entry {
        return self.entryStore()[0..self.entry_count];
    }

    pub fn entryPath(self: *const Catalog, entry: Entry) []const u8 {
        const start = entry.path_offset;
        std.debug.assert(start + entry.path_len <= self.path_used);
        return self.pathStore()[start..][0..entry.path_len];
    }

    pub fn directoryPath(self: *const Catalog, directory: Directory) []const u8 {
        const start = directory.path_offset;
        std.debug.assert(start + directory.path_len <= self.path_used);
        return self.pathStore()[start..][0..directory.path_len];
    }

    pub fn deinit(self: *Catalog) Storage {
        std.debug.assert(self.phase == .steady);
        self.phase = .teardown;
        const storage = self.storage;
        self.* = undefined;
        return storage;
    }

    fn reservePath(self: *Catalog, path: []const u8) CatalogExhaustion!u32 {
        std.debug.assert(path.len != 0);
        std.debug.assert(self.path_used <= self.capacity.path_bytes);
        if (path.len > path_bytes_limit) return error.FontPathBytesExhausted;
        const remaining = self.capacity.path_bytes - self.path_used;
        if (path.len > remaining) return error.FontPathBytesExhausted;
        const offset = self.path_used;
        @memcpy(self.pathStore()[offset..][0..path.len], path);
        self.path_used = offset + @as(u32, @intCast(path.len));
        std.debug.assert(self.path_used <= self.capacity.path_bytes);
        return offset;
    }

    fn entryStore(self: *const Catalog) []Entry {
        std.debug.assert(self.storage.len >= self.capacity.storage_bytes);
        const bytes = self.storage[0 .. self.capacity.entries * @sizeOf(Entry)];
        return @alignCast(std.mem.bytesAsSlice(Entry, bytes));
    }

    fn directoryStore(self: *const Catalog) []Directory {
        std.debug.assert(self.storage.len >= self.capacity.storage_bytes);
        const start = self.capacity.entries * @sizeOf(Entry);
        std.debug.assert(start % storage_alignment == 0);
        const count = self.capacity.directories * @sizeOf(Directory);
        const bytes = self.storage[start..][0..count];
        return @alignCast(std.mem.bytesAsSlice(Directory, bytes));
    }

    fn pathStore(self: *const Catalog) []u8 {
        std.debug.assert(self.storage.len >= self.capacity.storage_bytes);
        const start = self.capacity.entries * @sizeOf(Entry) +
            self.capacity.directories * @sizeOf(Directory);
        return self.storage[start..][0..self.capacity.path_bytes];
    }
};

comptime {
    capacity.requireProvisionedRejectingOwnerShape(Catalog);
}

comptime {
    std.debug.assert(@sizeOf(Entry) == 16);
    std.debug.assert(@sizeOf(Directory) == 24);
    std.debug.assert(@alignOf(Entry) <= Catalog.storage_alignment);
    std.debug.assert(@alignOf(Directory) <= Catalog.storage_alignment);
}

fn modelledStorageBytes(limits: Catalog.Limits) usize {
    return limits.entries * 16 + limits.directories * 24 + limits.path_bytes;
}
