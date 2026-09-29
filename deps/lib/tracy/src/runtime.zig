const std = @import("std");
const sys = @import("sys");
const build_options = @import("build_options");
const clock = @import("clock.zig");
const event = @import("event.zig");

pub const enabled = build_options.enabled;

pub const StartOptions = struct {
    name: []const u8 = "tiny",
    detail: ?[]const u8 = null,
};

pub const PlotUnit = union(enum) {
    number,
    nanoseconds,
    bytes,
    count,
    percent,
    hertz,
    watts,
    custom: []const u8,

    pub fn tag(self: PlotUnit) []const u8 {
        return switch (self) {
            .number => "number",
            .nanoseconds => "nanoseconds",
            .bytes => "bytes",
            .count => "count",
            .percent => "percent",
            .hertz => "hertz",
            .watts => "watts",
            .custom => |text| text,
        };
    }
};

pub const PlotConfig = struct {
    unit: PlotUnit = .number,
    step: bool = false,
    fill: bool = false,
    color: ?u32 = null,
};

pub const Zone = struct {
    id: u64 = 0,
    active: bool = false,

    pub inline fn end(self: Zone) void {
        if (enabled and self.active) global.endZone(self.id);
    }

    pub inline fn setText(self: Zone, text: []const u8) void {
        if (enabled and self.active) global.zoneText(self.id, text);
    }

    pub inline fn setName(self: Zone, name: []const u8) void {
        if (enabled and self.active) global.zoneName(self.id, name);
    }

    pub inline fn setColor(self: Zone, color: u32) void {
        if (enabled and self.active) global.zoneColor(self.id, color);
    }

    pub inline fn setValue(self: Zone, value: u64) void {
        if (enabled and self.active) global.zoneValue(self.id, value);
    }
};

pub const LockKind = enum {
    lock,
    shared,

    fn tag(self: LockKind) []const u8 {
        return switch (self) {
            .lock => "lock",
            .shared => "shared",
        };
    }
};

pub const SampleKind = enum {
    manual,
    wall,
    cpu,
    context_switch,
    hardware,

    pub fn tag(self: SampleKind) []const u8 {
        return switch (self) {
            .manual => "manual",
            .wall => "wall",
            .cpu => "cpu",
            .context_switch => "context-switch",
            .hardware => "hardware",
        };
    }
};

pub const SampleFrame = struct {
    name: ?[]const u8 = null,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    address: u64 = 0,
};

pub const Fiber = struct {
    id: u64 = 0,
    name: ?[]const u8 = null,
    group_hint: i32 = 0,
    active: bool = false,

    pub inline fn enter(self: Fiber) void {
        if (enabled and self.active) global.enterFiber(self);
    }

    pub inline fn leave(self: Fiber) void {
        if (enabled and self.active) global.leaveFiber(self.id);
    }
};

pub const GpuContextType = enum {
    unknown,
    opengl,
    vulkan,
    direct3d11,
    direct3d12,
    metal,
    custom,

    pub fn tag(self: GpuContextType) ?[]const u8 {
        return switch (self) {
            .unknown => null,
            .opengl => "opengl",
            .vulkan => "vulkan",
            .direct3d11 => "direct3d11",
            .direct3d12 => "direct3d12",
            .metal => "metal",
            .custom => "custom",
        };
    }
};

pub const GpuContextOptions = struct {
    name: ?[]const u8 = null,
    context_type: GpuContextType = .unknown,
    period: f64 = 1.0,
    gpu_time: ?i64 = null,
    has_calibration: bool = false,
    serial: bool = false,
};

pub const GpuContext = struct {
    id: u32 = 0,
    active: bool = false,

    pub inline fn zone(self: GpuContext, comptime name: [:0]const u8) GpuZone {
        return self.zoneAt(name, @src());
    }

    pub inline fn zoneAt(self: GpuContext, comptime name: [:0]const u8, comptime src: std.builtin.SourceLocation) GpuZone {
        if (enabled and self.active) return global.beginGpuZone(self.id, name, src, null, 0);
        return .{};
    }

    pub inline fn zoneColor(self: GpuContext, comptime name: [:0]const u8, comptime color: u32) GpuZone {
        return self.zoneColorAt(name, color, @src());
    }

    pub inline fn zoneColorAt(self: GpuContext, comptime name: [:0]const u8, comptime color: u32, comptime src: std.builtin.SourceLocation) GpuZone {
        if (enabled and self.active) return global.beginGpuZone(self.id, name, src, color, 0);
        return .{};
    }

    pub inline fn zoneQuery(self: GpuContext, comptime name: [:0]const u8, query: u32) GpuZone {
        return self.zoneQueryAt(name, query, @src());
    }

    pub inline fn zoneQueryAt(self: GpuContext, comptime name: [:0]const u8, query: u32, comptime src: std.builtin.SourceLocation) GpuZone {
        if (enabled and self.active) return global.beginGpuZone(self.id, name, src, null, query);
        return .{};
    }

    pub inline fn zoneDynamic(self: GpuContext, name: []const u8) GpuZone {
        if (enabled and self.active) return global.beginGpuZoneDynamic(self.id, name, 0);
        return .{};
    }

    pub inline fn setName(self: GpuContext, name: []const u8) void {
        if (enabled and self.active) global.gpuContextName(self.id, name);
    }

    pub inline fn nextQuery(self: GpuContext) u32 {
        if (enabled and self.active) return global.nextGpuQuery();
        return 0;
    }

    pub inline fn time(self: GpuContext, query: u32, gpu_time: i64) void {
        if (enabled and self.active) global.gpuTime(self.id, query, gpu_time);
    }

    pub inline fn sync(self: GpuContext, gpu_time: i64) void {
        if (enabled and self.active) global.gpuTimeSync(self.id, gpu_time);
    }

    pub inline fn calibrate(self: GpuContext, gpu_time: i64, cpu_delta_ns: i64) void {
        if (enabled and self.active) global.gpuCalibration(self.id, gpu_time, cpu_delta_ns);
    }

    pub inline fn annotationName(self: GpuContext, id: i64, name: []const u8) void {
        if (enabled and self.active) global.gpuAnnotationName(self.id, id, name);
    }

    pub inline fn annotate(self: GpuContext, id: i64, value: f64) void {
        if (enabled and self.active) global.gpuAnnotation(self.id, 0, id, value);
    }
};

pub const GpuZone = struct {
    context: u32 = 0,
    begin_query: u32 = 0,
    active: bool = false,

    pub inline fn end(self: GpuZone) void {
        if (enabled and self.active) global.endGpuZone(self.context, 0, false);
    }

    pub inline fn endQuery(self: GpuZone, query: u32) void {
        if (enabled and self.active) global.endGpuZone(self.context, query, false);
    }

    pub inline fn endSerial(self: GpuZone) void {
        if (enabled and self.active) global.endGpuZone(self.context, 0, true);
    }

    pub inline fn endWithTimes(self: GpuZone, gpu_start: i64, gpu_end: i64) void {
        if (enabled and self.active) global.endGpuZoneWithTimes(self.context, self.begin_query, 0, gpu_start, gpu_end, false);
    }

    pub inline fn endQueryWithTimes(self: GpuZone, query: u32, gpu_start: i64, gpu_end: i64) void {
        if (enabled and self.active) global.endGpuZoneWithTimes(self.context, self.begin_query, query, gpu_start, gpu_end, false);
    }

    pub inline fn annotate(self: GpuZone, id: i64, value: f64) void {
        if (enabled and self.active) global.gpuAnnotation(self.context, self.begin_query, id, value);
    }
};

pub const HardwareSampleKind = enum {
    cpu_cycle,
    instruction_retired,
    cache_reference,
    cache_miss,
    branch_retired,
    branch_miss,

    pub fn tag(self: HardwareSampleKind) []const u8 {
        return switch (self) {
            .cpu_cycle => "cpu-cycle",
            .instruction_retired => "instruction-retired",
            .cache_reference => "cache-reference",
            .cache_miss => "cache-miss",
            .branch_retired => "branch-retired",
            .branch_miss => "branch-miss",
        };
    }
};

pub const CpuTopology = struct {
    cpu: u32,
    package: u32 = 0,
    die: u32 = 0,
    core: u32 = 0,
};

pub const ContextSwitchOptions = struct {
    cpu: ?u32 = null,
    prev_thread: u64 = 0,
    next_thread: u64 = 0,
    reason: ?[]const u8 = null,
    state: ?[]const u8 = null,
    previous_cstate: ?u32 = null,
    prev_priority: ?i64 = null,
    next_priority: ?i64 = null,
};

pub const ThreadWakeupOptions = struct {
    thread: u64,
    cpu: ?u32 = null,
    reason: ?[]const u8 = null,
    priority_increment: ?i64 = null,
};

pub const Lock = struct {
    id: u64 = 0,
    active: bool = false,

    pub inline fn terminate(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_terminate);
    }

    pub inline fn wait(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_wait);
    }

    pub inline fn obtain(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_obtain);
    }

    pub inline fn release(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_release);
    }

    pub inline fn sharedWait(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_shared_wait);
    }

    pub inline fn sharedObtain(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_shared_obtain);
    }

    pub inline fn sharedRelease(self: Lock) void {
        if (enabled and self.active) global.lockEvent(self.id, .lock_shared_release);
    }

    pub inline fn markAt(self: Lock, comptime src: std.builtin.SourceLocation) void {
        if (enabled and self.active) global.lockMark(self.id, src);
    }

    pub inline fn setName(self: Lock, name: []const u8) void {
        if (enabled and self.active) global.lockName(self.id, name);
    }
};

const State = struct {
    mutex: sys.thread.Mutex = .{},
    writer: ?*std.Io.Writer = null,
    active: bool = false,
    failed: bool = false,
    next_seq: u64 = 1,
    next_zone_id: u64 = 1,
    next_lock_id: u64 = 1,
    next_sample_id: u64 = 1,
    next_fiber_id: u64 = 1,
    next_gpu_context_id: u32 = 1,
    next_gpu_query_id: u32 = 1,

    fn start(self: *State, writer: *std.Io.Writer, options: StartOptions) !bool {
        self.lock();
        defer self.unlock();
        if (self.active) return error.TraceAlreadyStarted;
        current_fiber_id = 0;
        self.writer = writer;
        self.active = true;
        self.failed = false;
        self.next_seq = 1;
        self.next_zone_id = 1;
        self.next_lock_id = 1;
        self.next_sample_id = 1;
        self.next_fiber_id = 1;
        self.next_gpu_context_id = 1;
        self.next_gpu_query_id = 1;
        self.writePhysicalLocked(.{
            .kind = .start,
            .name = options.name,
            .text = options.detail,
        }) catch |err| {
            self.disableLocked();
            return err;
        };
        return true;
    }

    fn stop(self: *State) void {
        self.lock();
        defer self.unlock();
        if (!self.active) return;
        self.writePhysicalLocked(.{ .kind = .stop }) catch {};
        if (self.writer) |writer| writer.flush() catch {};
        self.writer = null;
        self.active = false;
        self.failed = false;
        current_fiber_id = 0;
    }

    fn isActive(self: *State) bool {
        self.lock();
        defer self.unlock();
        return self.active and !self.failed;
    }

    fn beginZone(
        self: *State,
        comptime name: [:0]const u8,
        comptime src: std.builtin.SourceLocation,
        color: ?u32,
    ) Zone {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return .{};
        const id = self.next_zone_id;
        self.next_zone_id +|= 1;
        self.writeLocked(.{
            .kind = .zone_begin,
            .id = id,
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .column = src.column,
            .color = color,
        }) catch {
            self.disableLocked();
            return .{};
        };
        return .{ .id = id, .active = true };
    }

    fn announceLock(
        self: *State,
        comptime name: [:0]const u8,
        comptime src: std.builtin.SourceLocation,
        kind: LockKind,
    ) Lock {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return .{};
        const id = self.next_lock_id;
        self.next_lock_id +|= 1;
        self.writeLocked(.{
            .kind = .lock_announce,
            .id = id,
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .column = src.column,
            .lock_kind = kind.tag(),
        }) catch {
            self.disableLocked();
            return .{};
        };
        return .{ .id = id, .active = true };
    }

    fn endZone(self: *State, id: u64) void {
        self.emit(.{ .kind = .zone_end, .id = id });
    }

    fn zoneText(self: *State, id: u64, text: []const u8) void {
        self.emit(.{ .kind = .zone_text, .id = id, .text = text });
    }

    fn zoneName(self: *State, id: u64, name: []const u8) void {
        self.emit(.{ .kind = .zone_name, .id = id, .name = name });
    }

    fn zoneColor(self: *State, id: u64, color: u32) void {
        self.emit(.{ .kind = .zone_color, .id = id, .color = color });
    }

    fn zoneValue(self: *State, id: u64, value: u64) void {
        self.emit(.{ .kind = .zone_value, .id = id, .value_u64 = value });
    }

    fn lockEvent(self: *State, id: u64, kind: event.Kind) void {
        self.emit(.{ .kind = kind, .id = id });
    }

    fn lockMark(self: *State, id: u64, comptime src: std.builtin.SourceLocation) void {
        self.emit(.{
            .kind = .lock_mark,
            .id = id,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .column = src.column,
        });
    }

    fn lockName(self: *State, id: u64, name: []const u8) void {
        self.emit(.{ .kind = .lock_name, .id = id, .name = name });
    }

    fn createFiber(self: *State, name: []const u8, group_hint: i32) Fiber {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return .{};
        const id = self.next_fiber_id;
        self.next_fiber_id +|= 1;
        const fiber_handle = Fiber{
            .id = id,
            .name = name,
            .group_hint = group_hint,
            .active = true,
        };
        self.writePhysicalLocked(.{
            .kind = .fiber_name,
            .id = id,
            .name = name,
            .group_hint = group_hint,
        }) catch {
            self.disableLocked();
            return .{};
        };
        return fiber_handle;
    }

    fn enterFiber(self: *State, fiber_handle: Fiber) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        self.writePhysicalLocked(.{
            .kind = .fiber_enter,
            .id = fiber_handle.id,
            .name = fiber_handle.name,
            .group_hint = fiber_handle.group_hint,
        }) catch {
            self.disableLocked();
            return;
        };
        current_fiber_id = fiber_handle.id;
    }

    fn leaveFiber(self: *State, id: u64) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        const actual_id = if (id != 0) id else current_fiber_id;
        self.writePhysicalLocked(.{
            .kind = .fiber_leave,
            .id = actual_id,
        }) catch {
            self.disableLocked();
            return;
        };
        if (current_fiber_id == actual_id) current_fiber_id = 0;
    }

    fn createGpuContext(self: *State, options: GpuContextOptions) GpuContext {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return .{};
        const id = self.next_gpu_context_id;
        self.next_gpu_context_id +|= 1;
        self.writePhysicalLocked(.{
            .kind = .gpu_context,
            .name = options.name,
            .gpu_context = id,
            .gpu_time = options.gpu_time,
            .gpu_period = options.period,
            .gpu_context_type = options.context_type.tag(),
            .gpu_has_calibration = options.has_calibration,
            .gpu_serial = options.serial,
        }) catch {
            self.disableLocked();
            return .{};
        };
        return .{ .id = id, .active = true };
    }

    fn beginGpuZone(
        self: *State,
        context: u32,
        comptime name: [:0]const u8,
        comptime src: std.builtin.SourceLocation,
        color: ?u32,
        query: u32,
    ) GpuZone {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return .{};
        const actual_query = self.gpuQueryLocked(query);
        self.writePhysicalLocked(.{
            .kind = .gpu_zone_begin,
            .gpu_context = context,
            .gpu_query = actual_query,
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .column = src.column,
            .color = color,
        }) catch {
            self.disableLocked();
            return .{};
        };
        return .{ .context = context, .begin_query = actual_query, .active = true };
    }

    fn beginGpuZoneDynamic(self: *State, context: u32, name: []const u8, query: u32) GpuZone {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return .{};
        const actual_query = self.gpuQueryLocked(query);
        self.writePhysicalLocked(.{
            .kind = .gpu_zone_begin,
            .gpu_context = context,
            .gpu_query = actual_query,
            .name = name,
        }) catch {
            self.disableLocked();
            return .{};
        };
        return .{ .context = context, .begin_query = actual_query, .active = true };
    }

    fn endGpuZone(self: *State, context: u32, query: u32, serial: bool) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        const actual_query = self.gpuQueryLocked(query);
        self.writePhysicalLocked(.{
            .kind = .gpu_zone_end,
            .gpu_context = context,
            .gpu_query = actual_query,
            .gpu_serial = serial,
        }) catch self.disableLocked();
    }

    fn endGpuZoneWithTimes(self: *State, context: u32, begin_query: u32, end_query: u32, gpu_start: i64, gpu_end: i64, serial: bool) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        const actual_end_query = self.gpuQueryLocked(end_query);
        const end_time = clock.nowNs();
        const thread = clock.threadId();
        self.writeAtLocked(.{
            .kind = .gpu_zone_end,
            .gpu_context = context,
            .gpu_query = actual_end_query,
            .gpu_serial = serial,
        }, end_time, thread) catch {
            self.disableLocked();
            return;
        };
        self.writeAtLocked(.{
            .kind = .gpu_time,
            .gpu_context = context,
            .gpu_query = begin_query,
            .gpu_time = gpu_start,
        }, end_time, thread) catch {
            self.disableLocked();
            return;
        };
        self.writeAtLocked(.{
            .kind = .gpu_time,
            .gpu_context = context,
            .gpu_query = actual_end_query,
            .gpu_time = gpu_end,
        }, end_time, thread) catch {
            self.disableLocked();
            return;
        };
    }

    fn gpuContextName(self: *State, context: u32, name: []const u8) void {
        self.emitPhysical(.{ .kind = .gpu_context_name, .gpu_context = context, .name = name });
    }

    fn gpuTime(self: *State, context: u32, query: u32, gpu_time: i64) void {
        self.emitPhysical(.{ .kind = .gpu_time, .gpu_context = context, .gpu_query = query, .gpu_time = gpu_time });
    }

    fn gpuTimeSync(self: *State, context: u32, gpu_time: i64) void {
        self.emitPhysical(.{ .kind = .gpu_time_sync, .gpu_context = context, .gpu_time = gpu_time });
    }

    fn gpuCalibration(self: *State, context: u32, gpu_time: i64, cpu_delta_ns: i64) void {
        self.emitPhysical(.{
            .kind = .gpu_calibration,
            .gpu_context = context,
            .gpu_time = gpu_time,
            .gpu_cpu_delta_ns = cpu_delta_ns,
        });
    }

    fn gpuAnnotationName(self: *State, context: u32, id: i64, name: []const u8) void {
        self.emitPhysical(.{
            .kind = .gpu_annotation_name,
            .gpu_context = context,
            .gpu_annotation_id = id,
            .name = name,
        });
    }

    fn gpuAnnotation(self: *State, context: u32, query: u32, id: i64, value: f64) void {
        if (!std.math.isFinite(value)) return;
        self.emitPhysical(.{
            .kind = .gpu_annotation,
            .gpu_context = context,
            .gpu_query = if (query == 0) null else query,
            .gpu_annotation_id = id,
            .value_f64 = value,
        });
    }

    fn nextGpuQuery(self: *State) u32 {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return 0;
        return self.gpuQueryLocked(0);
    }

    fn recordThreadContext(self: *State, thread: u64, name: ?[]const u8) void {
        self.emitForThread(thread, .{
            .kind = .thread_context,
            .name = name,
        });
    }

    fn recordThreadPid(self: *State, thread: u64, pid: u64) void {
        self.emitForThread(thread, .{
            .kind = .thread_pid,
            .pid = pid,
        });
    }

    fn recordCpuTopology(self: *State, topology: CpuTopology) void {
        self.emitPhysical(.{
            .kind = .cpu_topology,
            .cpu = topology.cpu,
            .cpu_package = topology.package,
            .cpu_die = topology.die,
            .cpu_core = topology.core,
        });
    }

    fn recordSystemTime(self: *State, value: f64) void {
        if (!std.math.isFinite(value)) return;
        self.emitPhysical(.{
            .kind = .sys_time,
            .value_f64 = value,
        });
    }

    fn recordSystemPower(self: *State, name: []const u8, delta_uj: u64) void {
        self.emitPhysical(.{
            .kind = .sys_power,
            .name = name,
            .power_delta_uj = delta_uj,
        });
    }

    fn recordHardwareSample(self: *State, kind: HardwareSampleKind, address: u64) void {
        self.emitPhysical(.{
            .kind = .hw_sample,
            .address = address,
            .hw_sample_kind = kind.tag(),
        });
    }

    fn recordSampleAt(
        self: *State,
        comptime name: [:0]const u8,
        kind: SampleKind,
        comptime src: std.builtin.SourceLocation,
        weight: u64,
    ) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        const id = self.next_sample_id;
        self.next_sample_id +|= 1;
        const time_ns = clock.nowNs();
        const thread = clock.threadId();
        self.writeAtLocked(.{
            .kind = .sample,
            .id = id,
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .column = src.column,
            .value_u64 = sampleWeight(weight),
            .sample_kind = kind.tag(),
        }, time_ns, thread) catch {
            self.disableLocked();
            return;
        };
        self.writeAtLocked(.{
            .kind = .sample_frame,
            .id = id,
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .column = src.column,
            .sample_kind = kind.tag(),
        }, time_ns, thread) catch {
            self.disableLocked();
            return;
        };
    }

    fn recordSampleStack(self: *State, name: []const u8, kind: SampleKind, frames: []const SampleFrame, weight: u64) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        const id = self.next_sample_id;
        self.next_sample_id +|= 1;
        const time_ns = clock.nowNs();
        const thread = clock.threadId();
        const leaf: ?SampleFrame = if (frames.len == 0) null else frames[frames.len - 1];
        self.writeAtLocked(.{
            .kind = .sample,
            .id = id,
            .name = name,
            .function = if (leaf) |frame_info| frame_info.function else null,
            .file = if (leaf) |frame_info| frame_info.file else null,
            .line = if (leaf) |frame_info| frame_info.line else 0,
            .column = if (leaf) |frame_info| frame_info.column else 0,
            .address = if (leaf) |frame_info| frame_info.address else 0,
            .value_u64 = sampleWeight(weight),
            .sample_kind = kind.tag(),
        }, time_ns, thread) catch {
            self.disableLocked();
            return;
        };
        for (frames, 0..) |frame_info, index| {
            self.writeAtLocked(.{
                .kind = .sample_frame,
                .id = id,
                .depth = @intCast(index),
                .name = frame_info.name,
                .function = frame_info.function,
                .file = frame_info.file,
                .line = frame_info.line,
                .column = frame_info.column,
                .address = frame_info.address,
                .sample_kind = kind.tag(),
            }, time_ns, thread) catch {
                self.disableLocked();
                return;
            };
        }
    }

    fn recordContextSwitch(self: *State, options: ContextSwitchOptions) void {
        self.emit(.{
            .kind = .context_switch,
            .cpu = options.cpu,
            .prev_thread = options.prev_thread,
            .next_thread = options.next_thread,
            .context_reason = options.reason,
            .context_state = options.state,
            .previous_cstate = options.previous_cstate,
            .prev_priority = options.prev_priority,
            .next_priority = options.next_priority,
        });
    }

    fn recordThreadWakeup(self: *State, options: ThreadWakeupOptions) void {
        self.emit(.{
            .kind = .thread_wakeup,
            .target_thread = options.thread,
            .cpu = options.cpu,
            .context_reason = options.reason,
            .value_i64 = options.priority_increment,
        });
    }

    fn emit(self: *State, trace_event: event.TraceEvent) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        self.writeLocked(trace_event) catch self.disableLocked();
    }

    fn emitPhysical(self: *State, trace_event: event.TraceEvent) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        self.writePhysicalLocked(trace_event) catch self.disableLocked();
    }

    fn emitForThread(self: *State, thread: u64, trace_event: event.TraceEvent) void {
        self.lock();
        defer self.unlock();
        if (!self.active or self.failed) return;
        self.writeAtLocked(trace_event, clock.nowNs(), thread) catch self.disableLocked();
    }

    fn gpuQueryLocked(self: *State, query: u32) u32 {
        if (query != 0) return query;
        const actual = self.next_gpu_query_id;
        self.next_gpu_query_id +|= 1;
        return actual;
    }

    fn writeLocked(self: *State, trace_event: event.TraceEvent) !void {
        try self.writeAtLocked(trace_event, clock.nowNs(), logicalThreadId());
    }

    fn writePhysicalLocked(self: *State, trace_event: event.TraceEvent) !void {
        try self.writeAtLocked(trace_event, clock.nowNs(), clock.threadId());
    }

    fn writeAtLocked(self: *State, trace_event: event.TraceEvent, time_ns: u64, thread: u64) !void {
        const writer = self.writer orelse return error.TraceNotStarted;
        var output = trace_event;
        output.seq = self.next_seq;
        output.time_ns = time_ns;
        output.thread = thread;
        self.next_seq +|= 1;
        try output.writeJsonLine(writer);
    }

    fn disableLocked(self: *State) void {
        self.failed = true;
        self.active = false;
        self.writer = null;
    }

    fn lock(self: *State) void {
        self.mutex.lock();
    }

    fn unlock(self: *State) void {
        self.mutex.unlock();
    }
};

var global: State = .{};
threadlocal var current_fiber_id: u64 = 0;

pub fn start(writer: *std.Io.Writer, options: StartOptions) !bool {
    if (!enabled) return false;
    return try global.start(writer, options);
}

pub fn stop() void {
    if (enabled) global.stop();
}

pub fn isActive() bool {
    if (!enabled) return false;
    return global.isActive();
}

pub inline fn zoneAt(
    comptime name: [:0]const u8,
    comptime src: std.builtin.SourceLocation,
    color: ?u32,
) Zone {
    if (!enabled) return .{};
    return global.beginZone(name, src, color);
}

pub inline fn lockableAt(
    comptime name: [:0]const u8,
    comptime src: std.builtin.SourceLocation,
) Lock {
    if (!enabled) return .{};
    return global.announceLock(name, src, .lock);
}

pub inline fn sharedLockableAt(
    comptime name: [:0]const u8,
    comptime src: std.builtin.SourceLocation,
) Lock {
    if (!enabled) return .{};
    return global.announceLock(name, src, .shared);
}

pub fn frame(name: ?[]const u8) void {
    if (!enabled) return;
    global.emit(.{ .kind = .frame, .name = name });
}

pub fn message(text: []const u8) void {
    if (!enabled) return;
    global.emit(.{ .kind = .message, .text = text });
}

pub fn appInfo(text: []const u8) void {
    if (!enabled) return;
    global.emit(.{ .kind = .app_info, .text = text });
}

pub fn plotConfig(name: []const u8, config: PlotConfig) void {
    if (!enabled) return;
    const unit = config.unit.tag();
    std.debug.assert(unit.len > 0);
    global.emit(.{
        .kind = .plot_config,
        .name = name,
        .color = config.color,
        .plot_unit = unit,
        .plot_step = config.step,
        .plot_fill = config.fill,
    });
}

pub fn plotFloat(name: []const u8, value: f64) void {
    if (!enabled or !std.math.isFinite(value)) return;
    global.emit(.{
        .kind = .plot,
        .name = name,
        .value_f64 = value,
        .plot_kind = "float",
    });
}

pub fn plotInt(name: []const u8, value: i64) void {
    if (!enabled) return;
    global.emit(.{
        .kind = .plot,
        .name = name,
        .value_i64 = value,
        .plot_kind = "int",
    });
}

pub fn alloc(ptr: ?*const anyopaque, size: usize) void {
    if (!enabled) return;
    allocNamed(ptr, size, null);
}

pub fn allocNamed(ptr: ?*const anyopaque, size: usize, name: ?[]const u8) void {
    if (!enabled) return;
    allocAddress(ptrAddress(ptr), size, name);
}

pub fn allocAddress(address: u64, size: usize, name: ?[]const u8) void {
    if (!enabled) return;
    global.emit(.{
        .kind = .alloc,
        .name = name,
        .address = address,
        .size = @intCast(size),
    });
}

pub fn free(ptr: ?*const anyopaque) void {
    if (!enabled) return;
    freeSizedNamed(ptr, 0, null);
}

pub fn freeNamed(ptr: ?*const anyopaque, name: ?[]const u8) void {
    if (!enabled) return;
    freeSizedNamed(ptr, 0, name);
}

pub fn freeSized(ptr: ?*const anyopaque, size: usize) void {
    if (!enabled) return;
    freeSizedNamed(ptr, size, null);
}

pub fn freeSizedNamed(ptr: ?*const anyopaque, size: usize, name: ?[]const u8) void {
    if (!enabled) return;
    freeAddress(ptrAddress(ptr), size, name);
}

pub fn freeAddress(address: u64, size: usize, name: ?[]const u8) void {
    if (!enabled) return;
    global.emit(.{
        .kind = .free,
        .name = name,
        .address = address,
        .size = @intCast(size),
    });
}

pub fn threadName(name: []const u8) void {
    if (!enabled) return;
    global.lock();
    defer global.unlock();
    if (!global.active or global.failed) return;
    global.writePhysicalLocked(.{ .kind = .thread_name, .name = name }) catch global.disableLocked();
}

pub fn fiber(name: []const u8, group_hint: i32) Fiber {
    if (!enabled) return .{};
    return global.createFiber(name, group_hint);
}

pub fn gpuContext(options: GpuContextOptions) GpuContext {
    if (!enabled) return .{};
    return global.createGpuContext(options);
}

fn ptrAddress(ptr: ?*const anyopaque) u64 {
    const actual = ptr orelse return 0;
    return @intCast(@intFromPtr(actual));
}

fn sampleWeight(weight: u64) ?u64 {
    if (weight == 1) return null;
    return weight;
}

pub inline fn sampleAt(
    comptime name: [:0]const u8,
    kind: SampleKind,
    comptime src: std.builtin.SourceLocation,
) void {
    if (!enabled) return;
    global.recordSampleAt(name, kind, src, 1);
}

pub inline fn sampleWeightedAt(
    comptime name: [:0]const u8,
    kind: SampleKind,
    weight: u64,
    comptime src: std.builtin.SourceLocation,
) void {
    if (!enabled) return;
    global.recordSampleAt(name, kind, src, weight);
}

pub fn sampleStack(name: []const u8, kind: SampleKind, frames: []const SampleFrame) void {
    if (!enabled) return;
    global.recordSampleStack(name, kind, frames, 1);
}

pub fn sampleStackWeighted(name: []const u8, kind: SampleKind, frames: []const SampleFrame, weight: u64) void {
    if (!enabled) return;
    global.recordSampleStack(name, kind, frames, weight);
}

pub fn contextSwitch(options: ContextSwitchOptions) void {
    if (!enabled) return;
    global.recordContextSwitch(options);
}

pub fn threadWakeup(options: ThreadWakeupOptions) void {
    if (!enabled) return;
    global.recordThreadWakeup(options);
}

pub fn threadContext(thread: u64, name: ?[]const u8) void {
    if (!enabled) return;
    global.recordThreadContext(thread, name);
}

pub fn threadPid(thread: u64, pid: u64) void {
    if (!enabled) return;
    global.recordThreadPid(thread, pid);
}

pub fn cpuTopology(topology: CpuTopology) void {
    if (!enabled) return;
    global.recordCpuTopology(topology);
}

pub fn systemTime(value: f64) void {
    if (!enabled) return;
    global.recordSystemTime(value);
}

pub fn systemPower(name: []const u8, delta_uj: u64) void {
    if (!enabled) return;
    global.recordSystemPower(name, delta_uj);
}

pub fn hardwareSample(kind: HardwareSampleKind, address: u64) void {
    if (!enabled) return;
    global.recordHardwareSample(kind, address);
}

fn logicalThreadId() u64 {
    if (current_fiber_id != 0) return current_fiber_id;
    return clock.threadId();
}

test "disabled runtime start is inert" {
    if (enabled) return;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!(try start(&out.writer, .{})));
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(!isActive());
}
