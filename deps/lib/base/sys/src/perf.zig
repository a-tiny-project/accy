const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const memory = @import("memory.zig");

const native_endian = builtin.target.cpu.arch.endian();
const linux = std.os.linux;
const posix = std.posix;

pub const required_capabilities = capabilities.host(&.{ .descriptors, .memory_mapping, .performance_counters, .time });

pub const supported = builtin.os.tag == .linux;

pub const header_size = 8;
pub const data_pages = 2;
pub const page_size = std.heap.page_size_min;
pub const data_size = data_pages * page_size;
pub const mmap_size = data_size + page_size;
pub const default_sample_type = linux.PERF.SAMPLE.IP | linux.PERF.SAMPLE.CALLCHAIN;
pub const invalid_fd: posix.fd_t = -1;

comptime {
    std.debug.assert(data_pages > 0);
    std.debug.assert(std.heap.page_size_min <= std.heap.page_size_max);
    std.debug.assert(
        std.heap.page_size_max <=
            std.math.maxInt(usize) / (data_pages + 1),
    );
}

pub const ReadFormat = struct {
    pub const total_time_enabled: u64 = 1 << 0;
    pub const total_time_running: u64 = 1 << 1;
    pub const id: u64 = 1 << 2;
    pub const group: u64 = 1 << 3;
    pub const lost: u64 = 1 << 4;
};

pub const SampleField = enum(u64) {
    ip = linux.PERF.SAMPLE.IP,
    pid_tid = linux.PERF.SAMPLE.TID,
    time = linux.PERF.SAMPLE.TIME,
    addr = linux.PERF.SAMPLE.ADDR,
    read = linux.PERF.SAMPLE.READ,
    callchain = linux.PERF.SAMPLE.CALLCHAIN,
    id = linux.PERF.SAMPLE.ID,
    cpu = linux.PERF.SAMPLE.CPU,
    period = linux.PERF.SAMPLE.PERIOD,
    stream_id = linux.PERF.SAMPLE.STREAM_ID,
    raw = linux.PERF.SAMPLE.RAW,
    branch_stack = linux.PERF.SAMPLE.BRANCH_STACK,
    regs = linux.PERF.SAMPLE.REGS_USER,
    stack = linux.PERF.SAMPLE.STACK_USER,
    _,
};

pub const RecordType = enum(u32) {
    mmap = 1,
    lost = 2,
    comm = 3,
    exit = 4,
    throttle = 5,
    unthrottle = 6,
    fork = 7,
    read = 8,
    sample = 9,
    mmap2 = 10,
    lost_samples = 13,
    _,
};

pub const Config = struct {
    sample_type: u64 = 0,
    read_format: u64 = 0,

    pub fn fromAttr(attr: linux.perf_event_attr) Config {
        return .{ .sample_type = attr.sample_type, .read_format = attr.read_format };
    }

    pub fn isSampling(self: Config, field: SampleField) bool {
        return self.sample_type & sampleBit(field) != 0;
    }
};

pub const SamplerOptions = struct {
    sample_period_ns: u64 = 1_000_000,
    sample_batch_size: u32 = 10,
    sample_type: u64 = default_sample_type,
    read_format: u64 = 0,
    exclude_kernel: bool = true,
    exclude_idle: bool = true,
};

pub const HardwareCounter = enum {
    cycles,
    instructions,
    cache_references,
    cache_misses,
    branch_instructions,
    branch_misses,
    bus_cycles,
    stalled_cycles_frontend,
    stalled_cycles_backend,
    reference_cycles,

    fn config(self: HardwareCounter) linux.PERF.COUNT.HW {
        return switch (self) {
            .cycles => .CPU_CYCLES,
            .instructions => .INSTRUCTIONS,
            .cache_references => .CACHE_REFERENCES,
            .cache_misses => .CACHE_MISSES,
            .branch_instructions => .BRANCH_INSTRUCTIONS,
            .branch_misses => .BRANCH_MISSES,
            .bus_cycles => .BUS_CYCLES,
            .stalled_cycles_frontend => .STALLED_CYCLES_FRONTEND,
            .stalled_cycles_backend => .STALLED_CYCLES_BACKEND,
            .reference_cycles => .REF_CPU_CYCLES,
        };
    }
};

pub const SoftwareCounter = enum {
    cpu_clock,
    task_clock,
    page_faults,
    context_switches,
    cpu_migrations,
    minor_faults,
    major_faults,
    alignment_faults,
    emulation_faults,
    dummy,

    fn config(self: SoftwareCounter) linux.PERF.COUNT.SW {
        return switch (self) {
            .cpu_clock => .CPU_CLOCK,
            .task_clock => .TASK_CLOCK,
            .page_faults => .PAGE_FAULTS,
            .context_switches => .CONTEXT_SWITCHES,
            .cpu_migrations => .CPU_MIGRATIONS,
            .minor_faults => .PAGE_FAULTS_MIN,
            .major_faults => .PAGE_FAULTS_MAJ,
            .alignment_faults => .ALIGNMENT_FAULTS,
            .emulation_faults => .EMULATION_FAULTS,
            .dummy => .DUMMY,
        };
    }
};

pub const CacheKind = enum {
    l1_data,
    l1_instruction,
    last_level,
    data_tlb,
    instruction_tlb,
    branch_predictor,
    node,

    fn config(self: CacheKind) linux.PERF.COUNT.HW.CACHE {
        return switch (self) {
            .l1_data => .L1D,
            .l1_instruction => .L1I,
            .last_level => .LL,
            .data_tlb => .DTLB,
            .instruction_tlb => .ITLB,
            .branch_predictor => .BPU,
            .node => .NODE,
        };
    }
};

pub const CacheOperation = enum {
    read,
    write,
    prefetch,

    fn config(self: CacheOperation) linux.PERF.COUNT.HW.CACHE.OP {
        return switch (self) {
            .read => .READ,
            .write => .WRITE,
            .prefetch => .PREFETCH,
        };
    }
};

pub const CacheResult = enum {
    access,
    miss,

    fn config(self: CacheResult) linux.PERF.COUNT.HW.CACHE.RESULT {
        return switch (self) {
            .access => .ACCESS,
            .miss => .MISS,
        };
    }
};

pub const CacheCounter = struct {
    cache: CacheKind,
    operation: CacheOperation,
    result: CacheResult,

    pub fn config(self: CacheCounter) u64 {
        return @as(u64, @backingInt(self.cache.config())) |
            (@as(u64, @backingInt(self.operation.config())) << 8) |
            (@as(u64, @backingInt(self.result.config())) << 16);
    }
};

pub const CounterOptions = struct {
    read_format: u64 = 0,
    exclude_kernel: bool = true,
    exclude_hv: bool = true,
    exclude_idle: bool = false,
    inherit: bool = false,
};

pub const CounterSelector = union(enum) {
    hardware: HardwareCounter,
    software: SoftwareCounter,
    cache: CacheCounter,
    raw: u64,

    pub fn attr(self: CounterSelector, options: CounterOptions) linux.perf_event_attr {
        var result = counterAttr(options);
        switch (self) {
            .hardware => |counter| {
                result.type = .HARDWARE;
                result.config = @backingInt(counter.config());
            },
            .software => |counter| {
                result.type = .SOFTWARE;
                result.config = @backingInt(counter.config());
            },
            .cache => |counter| {
                result.type = .HW_CACHE;
                result.config = counter.config();
            },
            .raw => |config| {
                result.type = .RAW;
                result.config = config;
            },
        }
        return result;
    }
};

pub const CountCoverage = enum {
    unknown,
    complete,
    multiplexed,
    not_counted,
    invalid,

    pub fn text(self: CountCoverage) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .complete => "complete",
            .multiplexed => "multiplexed",
            .not_counted => "not_counted",
            .invalid => "invalid",
        };
    }
};

pub const CountResult = struct {
    value: u64,
    time_enabled: ?u64 = null,
    time_running: ?u64 = null,
    id: ?u64 = null,
    lost: ?u64 = null,

    pub fn runningCoverage(self: CountResult) CountCoverage {
        const enabled = self.time_enabled orelse {
            if (self.time_running == null) return .unknown;
            return .invalid;
        };
        const running = self.time_running orelse return .invalid;
        if (running == 0) return .not_counted;
        if (running > enabled) return .invalid;
        if (running == enabled) return .complete;
        return .multiplexed;
    }

    pub fn scaledValue(self: CountResult) ?u64 {
        return switch (self.runningCoverage()) {
            .unknown, .complete => self.value,
            .multiplexed => blk: {
                const enabled = self.time_enabled.?;
                const running = self.time_running.?;
                const scaled = (@as(u128, self.value) * enabled) / running;
                break :blk std.math.cast(u64, scaled) orelse std.math.maxInt(u64);
            },
            .not_counted, .invalid => null,
        };
    }

    pub fn runningRatio(self: CountResult) ?f64 {
        return switch (self.runningCoverage()) {
            .complete, .multiplexed => ratio(self.time_running.?, self.time_enabled.?),
            .not_counted => if (self.time_enabled.? == 0) null else 0.0,
            .unknown, .invalid => null,
        };
    }

    pub fn parse(bytes: []const u8, read_format: u64) !CountResult {
        if (read_format & ReadFormat.group != 0) return error.UnsupportedReadFormat;
        var offset: usize = 0;
        var result = CountResult{ .value = try readCountField(bytes, &offset) };
        if (read_format & ReadFormat.total_time_enabled != 0) result.time_enabled = try readCountField(bytes, &offset);
        if (read_format & ReadFormat.total_time_running != 0) result.time_running = try readCountField(bytes, &offset);
        if (read_format & ReadFormat.id != 0) result.id = try readCountField(bytes, &offset);
        if (read_format & ReadFormat.lost != 0) result.lost = try readCountField(bytes, &offset);
        if (offset != bytes.len) return error.TrailingPerfEventReadData;
        return result;
    }
};

pub const CounterMeasurement = struct {
    selector: CounterSelector,
    result: CountResult,
};

pub fn CounterSetResult(comptime capacity: usize) type {
    if (capacity == 0) @compileError("counter set capacity must be positive");
    return struct {
        measurements: [capacity]CounterMeasurement = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *const Self) []const CounterMeasurement {
            std.debug.assert(self.len <= capacity);
            return self.measurements[0..self.len];
        }

        pub fn find(self: *const Self, selector: CounterSelector) ?CountResult {
            for (self.slice()) |measurement| {
                if (std.meta.eql(measurement.selector, selector)) return measurement.result;
            }
            return null;
        }

        pub fn parse(
            bytes: []const u8,
            read_format: u64,
            selectors: []const CounterSelector,
            expected_ids: []const u64,
        ) !Self {
            return parseCounterSetResult(capacity, bytes, read_format, selectors, expected_ids);
        }
    };
}

fn parseCounterSetResult(
    comptime capacity: usize,
    bytes: []const u8,
    read_format: u64,
    selectors: []const CounterSelector,
    expected_ids: []const u64,
) !CounterSetResult(capacity) {
    try validateCounterSetInput(capacity, read_format, selectors, expected_ids);
    var offset: usize = 0;
    const reported_count = std.math.cast(
        usize,
        try readCountField(bytes, &offset),
    ) orelse return error.CounterSetCountTooLarge;
    if (reported_count != selectors.len) return error.CounterSetCountMismatch;
    const time_enabled = try readOptionalGroupTime(bytes, &offset, read_format, .enabled);
    const time_running = try readOptionalGroupTime(bytes, &offset, read_format, .running);

    var result: CounterSetResult(capacity) = .{ .len = selectors.len };
    var seen: [capacity]bool = @splat(false);
    for (0..reported_count) |_| {
        var count: CountResult = .{
            .value = try readCountField(bytes, &offset),
            .time_enabled = time_enabled,
            .time_running = time_running,
            .id = try readCountField(bytes, &offset),
        };
        if (read_format & ReadFormat.lost != 0) {
            count.lost = try readCountField(bytes, &offset);
        }
        const requested_index = findCounterId(expected_ids, count.id.?) orelse
            return error.UnknownCounterSetId;
        if (seen[requested_index]) return error.DuplicateCounterSetId;
        seen[requested_index] = true;
        result.measurements[requested_index] = .{
            .selector = selectors[requested_index],
            .result = count,
        };
    }
    if (offset != bytes.len) return error.TrailingPerfEventReadData;
    for (seen[0..selectors.len]) |matched| {
        if (!matched) return error.MissingCounterSetId;
    }
    return result;
}

fn validateCounterSetInput(
    comptime capacity: usize,
    read_format: u64,
    selectors: []const CounterSelector,
    expected_ids: []const u64,
) !void {
    if (read_format & ReadFormat.group == 0) return error.CounterSetGroupFormatRequired;
    if (read_format & ReadFormat.id == 0) return error.CounterSetIdFormatRequired;
    if (selectors.len == 0) return error.EmptyCounterSet;
    if (selectors.len > capacity) return error.CounterSetCapacityExceeded;
    if (selectors.len != expected_ids.len) return error.CounterSetIdentityCountMismatch;
    try requireUniqueCounterSelectors(selectors);
    try requireUniqueCounterIds(expected_ids);
}

const GroupTime = enum { enabled, running };

fn readOptionalGroupTime(
    bytes: []const u8,
    offset: *usize,
    read_format: u64,
    field: GroupTime,
) !?u64 {
    const mask = switch (field) {
        .enabled => ReadFormat.total_time_enabled,
        .running => ReadFormat.total_time_running,
    };
    if (read_format & mask == 0) return null;
    return try readCountField(bytes, offset);
}

fn requireUniqueCounterIds(ids: []const u64) !void {
    for (ids, 0..) |id, index| {
        if (findCounterId(ids[0..index], id) != null) return error.DuplicateExpectedCounterSetId;
    }
}

fn requireUniqueCounterSelectors(selectors: []const CounterSelector) !void {
    for (selectors, 0..) |selector, index| {
        for (selectors[0..index]) |previous| {
            if (std.meta.eql(selector, previous)) return error.DuplicateCounterSetSelector;
        }
    }
}

fn findCounterId(ids: []const u64, target: u64) ?usize {
    for (ids, 0..) |id, index| {
        if (id == target) return index;
    }
    return null;
}

fn ratio(numerator: u64, denominator: u64) f64 {
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

pub const CounterRegion = struct {
    event: Event = .{},
    active: bool = false,

    pub fn start(selector: CounterSelector, options: CounterOptions) !CounterRegion {
        var event = try Event.openCounter(selector, options);
        errdefer event.close();
        try event.start();
        return .{ .event = event, .active = true };
    }

    pub fn stop(self: *CounterRegion) !CountResult {
        if (!self.active) return error.CounterRegionStopped;
        try self.event.stop();
        self.active = false;
        return self.event.countResult();
    }

    pub fn deinit(self: *CounterRegion) void {
        self.event.close();
        self.active = false;
    }
};

pub fn CounterSetRegion(comptime capacity: usize) type {
    if (capacity == 0) @compileError("counter set capacity must be positive");
    return struct {
        events: [capacity]Event = @splat(.{}),
        selectors: [capacity]CounterSelector = undefined,
        ids: [capacity]u64 = undefined,
        len: usize = 0,
        active: bool = false,

        const Self = @This();
        pub const Result: type = CounterSetResult(capacity);

        pub fn start(selectors: []const CounterSelector, options: CounterOptions) !Self {
            if (selectors.len == 0) return error.EmptyCounterSet;
            if (selectors.len > capacity) return error.CounterSetCapacityExceeded;
            if (options.inherit) return error.InheritedCounterSetUnsupported;
            try requireUniqueCounterSelectors(selectors);

            var region: Self = .{};
            errdefer region.deinit();
            var group_options = options;
            group_options.read_format |= ReadFormat.group | ReadFormat.id |
                ReadFormat.total_time_enabled | ReadFormat.total_time_running;
            for (selectors, 0..) |selector, index| {
                region.events[index] = if (index == 0)
                    try Event.openCounter(selector, group_options)
                else
                    try Event.openCounterMember(selector, group_options, region.events[0].fd);
                region.len = index + 1;
                region.selectors[index] = selector;
                region.ids[index] = try region.events[index].id();
            }
            try control(
                region.events[0].fd,
                linux.PERF.EVENT_IOC.ENABLE,
                linux.PERF.IOC_FLAG_GROUP,
            );
            region.active = true;
            return region;
        }

        pub fn stop(self: *Self) !Result {
            if (!self.active) return error.CounterSetRegionStopped;
            try control(
                self.events[0].fd,
                linux.PERF.EVENT_IOC.DISABLE,
                linux.PERF.IOC_FLAG_GROUP,
            );
            self.active = false;

            var bytes: [counterSetReadCapacity(capacity)]u8 = undefined;
            const read_format = self.events[0].config.read_format;
            const expected = try counterSetReadSize(read_format, self.len);
            const got = try posix.read(self.events[0].fd, bytes[0..expected]);
            if (got != expected) return error.ShortPerfEventRead;
            return Result.parse(
                bytes[0..got],
                read_format,
                self.selectors[0..self.len],
                self.ids[0..self.len],
            );
        }

        pub fn deinit(self: *Self) void {
            for (self.events[0..self.len]) |*event| event.close();
            self.len = 0;
            self.active = false;
        }
    };
}

pub fn taskClockSamplerAttr(options: SamplerOptions) linux.perf_event_attr {
    var attr: linux.perf_event_attr = .{};
    attr.type = .SOFTWARE;
    attr.config = @backingInt(linux.PERF.COUNT.SW.TASK_CLOCK);
    attr.sample_period_or_freq = options.sample_period_ns;
    attr.sample_type = options.sample_type;
    attr.read_format = options.read_format;
    attr.wakeup_events_or_watermark = options.sample_batch_size;
    attr.flags.disabled = true;
    attr.flags.exclude_idle = options.exclude_idle;
    attr.flags.exclude_kernel = options.exclude_kernel;
    return attr;
}

pub fn counterAttr(options: CounterOptions) linux.perf_event_attr {
    var attr: linux.perf_event_attr = .{};
    attr.read_format = options.read_format;
    attr.flags.disabled = true;
    attr.flags.exclude_idle = options.exclude_idle;
    attr.flags.exclude_kernel = options.exclude_kernel;
    attr.flags.exclude_hv = options.exclude_hv;
    attr.flags.inherit = options.inherit;
    return attr;
}

pub const Event = struct {
    fd: posix.fd_t = invalid_fd,
    mapping: ?[]align(page_size) u8 = null,
    config: Config = .{},
    mapped_page_size: usize = page_size,

    pub fn open(attr: *linux.perf_event_attr, pid: posix.pid_t, cpu: i32) !Event {
        if (comptime !supported) return error.UnsupportedPlatform;
        attr.flags.disabled = true;
        return openLinux(attr, pid, cpu, invalid_fd);
    }

    pub fn openTaskClockSampler(options: SamplerOptions) !Event {
        if (comptime !supported) return error.UnsupportedPlatform;
        var attr = taskClockSamplerAttr(options);
        return open(&attr, 0, -1);
    }

    pub fn openCounter(selector: CounterSelector, options: CounterOptions) !Event {
        if (comptime !supported) return error.UnsupportedPlatform;
        var attr = selector.attr(options);
        return open(&attr, 0, -1);
    }

    fn openCounterMember(
        selector: CounterSelector,
        options: CounterOptions,
        group_fd: posix.fd_t,
    ) !Event {
        if (comptime !supported) return error.UnsupportedPlatform;
        var attr = selector.attr(options);
        attr.flags.disabled = false;
        return openLinux(&attr, 0, -1, group_fd);
    }

    pub fn close(self: *Event) void {
        if (self.mapping) |mapped| {
            memory.unmap(mapped);
            self.mapping = null;
        }
        if (self.fd != invalid_fd) {
            closeFd(self.fd);
            self.fd = invalid_fd;
        }
        self.config = .{};
        self.mapped_page_size = page_size;
    }

    pub fn start(self: *Event) !void {
        if (self.fd == invalid_fd) return error.InvalidPerfEvent;
        try control(self.fd, linux.PERF.EVENT_IOC.ENABLE, 0);
    }

    pub fn stop(self: *Event) !void {
        if (self.fd == invalid_fd) return error.InvalidPerfEvent;
        try control(self.fd, linux.PERF.EVENT_IOC.DISABLE, 0);
    }

    pub fn id(self: *Event) !u64 {
        if (self.fd == invalid_fd) return error.InvalidPerfEvent;
        return eventId(self.fd);
    }

    pub fn count(self: *Event) !u64 {
        return (try self.countResult()).value;
    }

    pub fn countResult(self: *Event) !CountResult {
        if (self.fd == invalid_fd) return error.InvalidPerfEvent;
        var bytes: [@sizeOf(u64) * 5]u8 = undefined;
        const expected = countReadSize(self.config.read_format) orelse return error.UnsupportedReadFormat;
        const got = try posix.read(self.fd, bytes[0..expected]);
        if (got != expected) return error.ShortPerfEventRead;
        return CountResult.parse(bytes[0..got], self.config.read_format);
    }

    pub fn ringReader(self: *Event) ?RingReader {
        const mapped = self.mapping orelse return null;
        const page = mappedPage(mapped);
        const head = @atomicLoad(u64, &page.data_head, .acquire);
        const tail = @atomicLoad(u64, &page.data_tail, .monotonic);
        return RingReader.init(self.config, mappedData(mapped, self.mapped_page_size), tail, head);
    }

    pub fn commitReader(self: *Event, reader: RingReader) void {
        const mapped = self.mapping orelse return;
        const page = mappedPage(mapped);
        @atomicStore(u64, &page.data_tail, reader.index, .release);
    }
};

fn openLinux(
    attr: *linux.perf_event_attr,
    pid: posix.pid_t,
    cpu: i32,
    group_fd: posix.fd_t,
) !Event {
    attr.size = @sizeOf(linux.perf_event_attr);

    const fd = try perfEventOpenLinux(attr, pid, cpu, group_fd, 0);
    errdefer closeFd(fd);

    var mapping: ?[]align(page_size) u8 = null;
    errdefer if (mapping) |mapped| memory.unmap(mapped);
    const actual_page_size = std.heap.pageSize();

    if (attr.sample_type != 0 and attr.sample_period_or_freq != 0) {
        mapping = try memory.mapSharedFile(
            fd,
            mmapSizeForPageSize(actual_page_size),
            .{ .read = true, .write = true },
            0,
        );
    }

    return .{
        .fd = fd,
        .mapping = mapping,
        .config = Config.fromAttr(attr.*),
        .mapped_page_size = actual_page_size,
    };
}

pub const Header = struct {
    record_type: RecordType,
    misc: u16,
    size: u16,

    pub fn parse(bytes: []const u8) !Header {
        if (bytes.len < header_size) return error.TruncatedRecordHeader;
        return .{
            .record_type = @fromBackingInt(@intCast(readAt(u32, bytes, 0))),
            .misc = readAt(u16, bytes, 4),
            .size = readAt(u16, bytes, 6),
        };
    }
};

pub const Callchain = struct {
    bytes: []const u8,

    pub fn len(self: Callchain) usize {
        return self.bytes.len / @sizeOf(u64);
    }

    pub fn at(self: Callchain, index: usize) u64 {
        std.debug.assert(index < self.len());
        return readAt(u64, self.bytes, index * @sizeOf(u64));
    }
};

pub const Record = struct {
    config: Config,
    header: Header,
    bytes: []const u8,

    pub fn init(config: Config, bytes: []const u8) !Record {
        const header = try Header.parse(bytes);
        if (header.size < header_size) return error.InvalidRecordSize;
        if (bytes.len < header.size) return error.TruncatedRecord;
        return .{ .config = config, .header = header, .bytes = bytes[0..header.size] };
    }

    pub fn recordType(self: Record) RecordType {
        return self.header.record_type;
    }

    pub fn isSample(self: Record) bool {
        return self.recordType() == .sample;
    }

    pub fn getLostCount(self: Record) !u64 {
        const offset: usize = switch (self.recordType()) {
            .lost => header_size + @sizeOf(u64),
            .lost_samples => header_size,
            else => return error.NotLostRecord,
        };
        try self.requireRange(offset, @sizeOf(u64));
        return readAt(u64, self.bytes, offset);
    }

    pub fn getIp(self: Record) !u64 {
        try self.expectSampleField(.ip);
        return self.readField(u64, .ip);
    }

    pub fn getPid(self: Record) !u32 {
        try self.expectSampleField(.pid_tid);
        const offset = try self.fieldOffset(.pid_tid);
        try self.requireRange(offset, 2 * @sizeOf(u32));
        return readAt(u32, self.bytes, offset);
    }

    pub fn getTid(self: Record) !u32 {
        try self.expectSampleField(.pid_tid);
        const offset = try self.fieldOffset(.pid_tid);
        try self.requireRange(offset, 2 * @sizeOf(u32));
        return readAt(u32, self.bytes, offset + @sizeOf(u32));
    }

    pub fn getTime(self: Record) !u64 {
        try self.expectSampleField(.time);
        return self.readField(u64, .time);
    }

    pub fn getCpu(self: Record) !u32 {
        try self.expectSampleField(.cpu);
        const offset = try self.fieldOffset(.cpu);
        try self.requireRange(offset, 2 * @sizeOf(u32));
        return readAt(u32, self.bytes, offset);
    }

    pub fn getPeriod(self: Record) !u64 {
        try self.expectSampleField(.period);
        return self.readField(u64, .period);
    }

    pub fn getCallchain(self: Record) !Callchain {
        try self.expectSampleField(.callchain);
        const offset = try self.fieldOffset(.callchain);
        const count = try self.readCountedLength(offset);
        const payload_offset = try self.advance(offset, @sizeOf(u64));
        const payload_size = try std.math.mul(usize, count, @sizeOf(u64));
        try self.requireRange(payload_offset, payload_size);
        return .{ .bytes = self.bytes[payload_offset..][0..payload_size] };
    }

    pub fn getRaw(self: Record) ![]const u8 {
        try self.expectSampleField(.raw);
        const offset = try self.fieldOffset(.raw);
        const payload_offset = try self.advance(offset, @sizeOf(u32));
        const size = readAt(u32, self.bytes, offset);
        try self.requireRange(payload_offset, size);
        return self.bytes[payload_offset..][0..size];
    }

    pub fn payloadEndOffset(self: Record) !usize {
        var offset: usize = header_size;
        inline for (field_order) |field| {
            offset = try self.skipSampleField(offset, field);
        }
        return offset;
    }

    fn readField(self: Record, comptime T: type, field: SampleField) !T {
        const offset = try self.fieldOffset(field);
        try self.requireRange(offset, @sizeOf(T));
        return readAt(T, self.bytes, offset);
    }

    fn expectSampleField(self: Record, field: SampleField) !void {
        if (!self.isSample()) return error.NotSampleRecord;
        if (!self.config.isSampling(field)) return error.FieldNotSampled;
    }

    fn fieldOffset(self: Record, target: SampleField) !usize {
        var offset: usize = header_size;
        inline for (field_order) |field| {
            if (field == target) return offset;
            offset = try self.skipSampleField(offset, field);
        }
        return error.UnsupportedSampleField;
    }

    fn skipSampleField(self: Record, offset: usize, field: SampleField) !usize {
        if (!self.config.isSampling(field)) return offset;
        switch (field) {
            .ip, .time, .addr, .id, .stream_id, .period => return self.advance(offset, @sizeOf(u64)),
            .pid_tid, .cpu => return self.advance(offset, @sizeOf(u32) + @sizeOf(u32)),
            .read => return self.skipReadField(offset),
            .callchain => {
                const count = try self.readCountedLength(offset);
                const payload_size = try std.math.mul(usize, count, @sizeOf(u64));
                const payload_offset = try self.advance(offset, @sizeOf(u64));
                return self.advance(payload_offset, payload_size);
            },
            .raw => {
                try self.requireRange(offset, @sizeOf(u32));
                const size = readAt(u32, self.bytes, offset);
                const payload_offset = try self.advance(offset, @sizeOf(u32));
                return self.advance(payload_offset, size);
            },
            .branch_stack, .regs, .stack => return error.UnsupportedSampleField,
            _ => return error.UnsupportedSampleField,
        }
    }

    fn skipReadField(self: Record, offset: usize) !usize {
        var cursor = offset;
        if (self.config.read_format & ReadFormat.group != 0) {
            const count = try self.readCountedLength(cursor);
            cursor = try self.advance(cursor, @sizeOf(u64));
            if (self.config.read_format & ReadFormat.total_time_enabled != 0) cursor = try self.advance(cursor, @sizeOf(u64));
            if (self.config.read_format & ReadFormat.total_time_running != 0) cursor = try self.advance(cursor, @sizeOf(u64));
            var member_fields: usize = 1;
            if (self.config.read_format & ReadFormat.id != 0) member_fields += 1;
            if (self.config.read_format & ReadFormat.lost != 0) member_fields += 1;
            std.debug.assert(member_fields <= 3);
            const member_size = member_fields * @sizeOf(u64);
            const members_size = try std.math.mul(usize, count, member_size);
            return self.advance(cursor, members_size);
        }

        cursor = try self.advance(cursor, @sizeOf(u64));
        if (self.config.read_format & ReadFormat.total_time_enabled != 0) cursor = try self.advance(cursor, @sizeOf(u64));
        if (self.config.read_format & ReadFormat.total_time_running != 0) cursor = try self.advance(cursor, @sizeOf(u64));
        if (self.config.read_format & ReadFormat.id != 0) cursor = try self.advance(cursor, @sizeOf(u64));
        if (self.config.read_format & ReadFormat.lost != 0) {
            cursor = try self.advance(cursor, @sizeOf(u64));
        }
        return cursor;
    }

    fn readCountedLength(self: Record, offset: usize) !usize {
        try self.requireRange(offset, @sizeOf(u64));
        return std.math.cast(usize, readAt(u64, self.bytes, offset)) orelse error.RecordFieldTooLarge;
    }

    fn advance(self: Record, offset: usize, size: usize) !usize {
        try self.requireRange(offset, size);
        return offset + size;
    }

    fn requireRange(self: Record, offset: usize, size: usize) !void {
        const end = std.math.add(usize, offset, size) catch return error.TruncatedRecord;
        if (end > self.bytes.len) return error.TruncatedRecord;
    }
};

pub const RingReader = struct {
    config: Config,
    data: []const u8,
    index: u64,
    head: u64,

    pub fn init(config: Config, data: []const u8, tail: u64, head: u64) RingReader {
        return .{ .config = config, .data = data, .index = tail, .head = head };
    }

    pub fn hasData(self: RingReader) !bool {
        if (self.head < self.index) return error.RingHeadBeforeTail;
        const available = self.head - self.index;
        if (available > self.data.len) return error.RingWindowExceedsBuffer;
        if (available < header_size) return false;

        var header_bytes: [header_size]u8 = undefined;
        try copyFromRingBuffer(self.data, self.index, &header_bytes);
        const header = try Header.parse(&header_bytes);
        if (header.size < header_size) return error.InvalidRecordSize;

        const record_limit = std.math.add(u64, self.index, header.size) catch return error.RingIndexOverflow;
        return record_limit <= self.head;
    }

    pub fn next(self: *RingReader, scratch: []u8) !?Record {
        if (!try self.hasData()) return null;

        var header_bytes: [header_size]u8 = undefined;
        try copyFromRingBuffer(self.data, self.index, &header_bytes);
        const header = try Header.parse(&header_bytes);
        if (header.size > scratch.len) return error.ScratchTooSmall;

        try copyFromRingBuffer(self.data, self.index, scratch[0..header.size]);
        self.index += header.size;
        return try Record.init(self.config, scratch[0..header.size]);
    }
};

pub fn sampleMask(fields: []const SampleField) u64 {
    var result: u64 = 0;
    for (fields) |field| result |= sampleBit(field);
    return result;
}

pub fn copyFromRingBuffer(data: []const u8, index: u64, dest: []u8) !void {
    if (dest.len == 0) return;
    if (data.len == 0) return error.EmptyRingBuffer;
    if (dest.len > data.len) return error.RecordLargerThanRing;

    const ring_len: u64 = @intCast(data.len);
    const start: usize = @intCast(index % ring_len);
    const end = start + dest.len;
    if (end <= data.len) {
        @memcpy(dest, data[start..end]);
        return;
    }

    const first_len = data.len - start;
    const second_len = dest.len - first_len;
    @memcpy(dest[0..first_len], data[start..]);
    @memcpy(dest[first_len..], data[0..second_len]);
}

const field_order = [_]SampleField{
    .ip,
    .pid_tid,
    .time,
    .addr,
    .id,
    .stream_id,
    .cpu,
    .period,
    .read,
    .callchain,
    .raw,
    .branch_stack,
    .regs,
    .stack,
};

fn sampleBit(field: SampleField) u64 {
    return @backingInt(field);
}

fn perfEventOpenLinux(
    attr: *linux.perf_event_attr,
    pid: posix.pid_t,
    cpu: i32,
    group_fd: posix.fd_t,
    flags: usize,
) !posix.fd_t {
    const rc = linux.perf_event_open(attr, pid, cpu, group_fd, flags);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .@"2BIG" => return error.TooBig,
        .ACCES => return error.PermissionDenied,
        .BADF,
        .FAULT,
        .INTR,
        .NOENT,
        => unreachable,
        .INVAL => return error.InvalidPerfEventOptions,
        .BUSY => return error.DeviceBusy,
        .MFILE => return error.ProcessResources,
        .NODEV => return error.EventRequiresUnsupportedCpuFeature,
        .NOSPC => return error.TooManyBreakpoints,
        .NOSYS => return error.SampleStackNotSupported,
        .OPNOTSUPP => return error.EventNotSupported,
        .OVERFLOW => return error.SampleMaxStackOverflow,
        .PERM => return error.PermissionDenied,
        .SRCH => return error.ProcessNotFound,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn control(fd: posix.fd_t, request: u32, argument: usize) !void {
    if (comptime !supported) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.ioctl(fd, request, argument);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF, .INVAL => return error.InvalidPerfEvent,
            .ACCES, .PERM => return error.PermissionDenied,
            else => return error.PerfEventControlFailed,
        }
    }
}

fn eventId(fd: posix.fd_t) !u64 {
    if (comptime !supported) return error.UnsupportedPlatform;
    var id: u64 = 0;
    while (true) {
        const rc = linux.ioctl(fd, linux.PERF.EVENT_IOC.ID, @intFromPtr(&id));
        switch (linux.errno(rc)) {
            .SUCCESS => return id,
            .INTR => continue,
            .BADF, .INVAL => return error.InvalidPerfEvent,
            .ACCES, .PERM => return error.PermissionDenied,
            else => return error.PerfEventIdFailed,
        }
    }
}

fn closeFd(fd: posix.fd_t) void {
    if (comptime !supported) return;
    switch (linux.errno(linux.close(fd))) {
        .SUCCESS, .INTR => {},
        else => unreachable,
    }
}

fn mappedPage(mapped: []align(page_size) u8) *linux.perf_event_mmap_page {
    return @ptrCast(mapped.ptr);
}

fn mappedData(mapped: []align(page_size) u8, actual_page_size: usize) []const u8 {
    return mapped[actual_page_size..][0..dataSizeForPageSize(actual_page_size)];
}

fn dataSizeForPageSize(actual_page_size: usize) usize {
    std.debug.assert(actual_page_size >= std.heap.page_size_min);
    std.debug.assert(actual_page_size <= std.heap.page_size_max);
    return data_pages * actual_page_size;
}

fn mmapSizeForPageSize(actual_page_size: usize) usize {
    const mapped_data_size = dataSizeForPageSize(actual_page_size);
    std.debug.assert(
        mapped_data_size <= std.math.maxInt(usize) - actual_page_size,
    );
    return mapped_data_size + actual_page_size;
}

fn readAt(comptime T: type, bytes: []const u8, offset: usize) T {
    std.debug.assert(@sizeOf(T) <= bytes.len);
    std.debug.assert(offset <= bytes.len - @sizeOf(T));
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], native_endian);
}

fn readCountField(bytes: []const u8, offset: *usize) !u64 {
    if (offset.* > bytes.len) return error.ShortPerfEventRead;
    if (@sizeOf(u64) > bytes.len - offset.*) return error.ShortPerfEventRead;
    const value = readAt(u64, bytes, offset.*);
    offset.* += @sizeOf(u64);
    return value;
}

fn countReadSize(read_format: u64) ?usize {
    if (read_format & ReadFormat.group != 0) return null;
    var result: usize = @sizeOf(u64);
    if (read_format & ReadFormat.total_time_enabled != 0) result += @sizeOf(u64);
    if (read_format & ReadFormat.total_time_running != 0) result += @sizeOf(u64);
    if (read_format & ReadFormat.id != 0) result += @sizeOf(u64);
    if (read_format & ReadFormat.lost != 0) result += @sizeOf(u64);
    return result;
}

fn counterSetReadCapacity(comptime capacity: usize) usize {
    return @sizeOf(u64) * (3 + 3 * capacity);
}

fn counterSetReadSize(read_format: u64, count: usize) !usize {
    if (read_format & ReadFormat.group == 0) return error.CounterSetGroupFormatRequired;
    var header_fields: usize = 1;
    if (read_format & ReadFormat.total_time_enabled != 0) header_fields += 1;
    if (read_format & ReadFormat.total_time_running != 0) header_fields += 1;
    var member_fields: usize = 1;
    if (read_format & ReadFormat.id != 0) member_fields += 1;
    if (read_format & ReadFormat.lost != 0) member_fields += 1;
    const member_total = try std.math.mul(usize, member_fields, count);
    const field_total = try std.math.add(usize, header_fields, member_total);
    return try std.math.mul(usize, field_total, @sizeOf(u64));
}

fn writeAt(comptime T: type, bytes: []u8, offset: *usize, value: T) void {
    std.mem.writeInt(T, bytes[offset.*..][0..@sizeOf(T)], value, native_endian);
    offset.* += @sizeOf(T);
}

fn finishRecord(bytes: []u8, len: usize, record_type: RecordType) []const u8 {
    std.mem.writeInt(u32, bytes[0..4], @backingInt(record_type), native_endian);
    std.mem.writeInt(u16, bytes[4..6], 0, native_endian);
    std.mem.writeInt(u16, bytes[6..8], @intCast(len), native_endian);
    return bytes[0..len];
}

fn finishSample(bytes: []u8, len: usize) []const u8 {
    return finishRecord(bytes, len, .sample);
}

fn writeRing(data: []u8, index: usize, bytes: []const u8) void {
    for (bytes, 0..) |byte, offset| {
        data[(index + offset) % data.len] = byte;
    }
}

fn expectCountEvidence(
    result: CountResult,
    coverage: CountCoverage,
    scaled: ?u64,
    running_ratio: ?f64,
) !void {
    try std.testing.expectEqual(coverage, result.runningCoverage());
    try std.testing.expectEqual(scaled, result.scaledValue());
    try std.testing.expectEqual(running_ratio, result.runningRatio());
}

const counter_set_test_format = ReadFormat.group | ReadFormat.total_time_enabled |
    ReadFormat.total_time_running | ReadFormat.id | ReadFormat.lost;

fn writeCounterSetTestRow(
    bytes: []u8,
    offset: *usize,
    value: u64,
    id: u64,
    lost: u64,
) void {
    writeAt(u64, bytes, offset, value);
    writeAt(u64, bytes, offset, id);
    writeAt(u64, bytes, offset, lost);
}

fn counterSetTestBytes(bytes: []u8, first_id: u64, second_id: u64) []const u8 {
    var offset: usize = 0;
    writeAt(u64, bytes, &offset, 2);
    writeAt(u64, bytes, &offset, 100);
    writeAt(u64, bytes, &offset, 50);
    writeCounterSetTestRow(bytes, &offset, 20, first_id, 2);
    writeCounterSetTestRow(bytes, &offset, 10, second_id, 1);
    return bytes[0..offset];
}
