const std = @import("std");
const builtin = @import("builtin");

const driver_mod = @import("sys").cuda;

const log = std.log.scoped(.cuda_runtime);

pub const Driver = driver_mod.Driver;
const CUjit_option = driver_mod.CUjit_option;
const CUresult = driver_mod.CUresult;
const CUdevice_attribute = driver_mod.CUdevice_attribute;
const CUfunction_attribute = driver_mod.CUfunction_attribute;
pub const Error = driver_mod.Error;
pub const CUdevice = driver_mod.CUdevice;
pub const CUcontext = driver_mod.CUcontext;
pub const CUmodule = driver_mod.CUmodule;
pub const CUfunction = driver_mod.CUfunction;
pub const CUdeviceptr = driver_mod.CUdeviceptr;
pub const CUstream = driver_mod.CUstream;
pub const CUevent = driver_mod.CUevent;
pub const CUgraph = driver_mod.CUgraph;
pub const CUgraphExec = driver_mod.CUgraphExec;

pub const Device = struct {
    handle: CUdevice,
    name_buf: [256]u8 = @as([256]u8, @splat(0)),
    name_len: u8 = 0,
    compute_capability: ComputeCapability = .{ .major = 0, .minor = 0 },
    shared_memory_per_block: u32 = 48 * 1024,
    shared_memory_per_block_optin: u32 = 48 * 1024,

    pub const ComputeCapability = struct { major: i32, minor: i32 };

    pub fn name(self: *const Device) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn supportsTf32TensorOps(self: *const Device) bool {
        return self.compute_capability.major >= 8;
    }

    pub fn dynamicSharedMemoryLimit(self: *const Device) u32 {
        return @max(self.shared_memory_per_block, self.shared_memory_per_block_optin);
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    driver: Driver,
    ctx: CUcontext,
    device: Device,
    module_cache: ModuleCache,
    default_stream_cached: ?*Stream,
    live_streams: std.AutoHashMapUnmanaged(*Stream, void),

    pub fn init(allocator: std.mem.Allocator, device_ordinal: i32) Error!Runtime {
        var drv = try Driver.open(allocator);
        errdefer drv.close();
        try drv.fromResult(drv.cuInit(0));

        var count: c_int = 0;
        try drv.fromResult(drv.cuDeviceGetCount(&count));
        if (count <= 0) return Error.CudaNoDevice;
        if (device_ordinal < 0 or device_ordinal >= count) {
            return Error.CudaInvalidDevice;
        }

        var dev_handle: CUdevice = 0;
        try drv.fromResult(drv.cuDeviceGet(&dev_handle, @intCast(device_ordinal)));
        const device = try queryDevice(&drv, dev_handle);

        var ctx: CUcontext = null;
        try drv.fromResult(drv.cuCtxCreate_v2(&ctx, 0, dev_handle));
        errdefer _ = drv.cuCtxDestroy_v2(ctx);

        return .{
            .allocator = allocator,
            .driver = drv,
            .ctx = ctx,
            .device = device,
            .module_cache = .{},
            .default_stream_cached = null,
            .live_streams = .{},
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.live_streams.count() != 0) {
            std.debug.panic(
                "Runtime.deinit: {d} caller-created stream(s) still live",
                .{self.live_streams.count()},
            );
        }
        self.live_streams.deinit(self.allocator);
        self.module_cache.deinit(self);
        if (self.default_stream_cached) |s| self.allocator.destroy(s);
        _ = self.driver.cuCtxDestroy_v2(self.ctx);
        self.driver.close();
        self.* = undefined;
    }

    pub fn defaultStream(self: *Runtime) Error!*Stream {
        if (self.default_stream_cached) |s| return s;
        const s = self.allocator.create(Stream) catch return Error.CudaOutOfMemory;
        s.* = .{
            .runtime = self,
            .handle = null,
            .is_default = true,
            .poisoned = false,
        };
        self.default_stream_cached = s;
        return s;
    }

    pub fn synchronize(self: *Runtime) Error!void {
        try self.driver.fromResult(self.driver.cuCtxSynchronize());
    }

    pub fn loadPtx(self: *Runtime, ptx: []const u8) Error!*Module {
        return self.module_cache.loadPtx(self, ptx);
    }

    pub fn createStream(self: *Runtime) Error!*Stream {
        const stream = self.allocator.create(Stream) catch return Error.CudaOutOfMemory;
        errdefer self.allocator.destroy(stream);

        var handle: CUstream = null;
        try self.driver.fromResult(self.driver.cuStreamCreate(&handle, 0));
        errdefer _ = self.driver.cuStreamDestroy_v2(handle);

        self.live_streams.put(self.allocator, stream, {}) catch return Error.CudaOutOfMemory;

        stream.* = .{
            .runtime = self,
            .handle = handle,
            .is_default = false,
            .poisoned = false,
        };
        return stream;
    }

    pub fn destroyStream(self: *Runtime, stream: *Stream) void {
        std.debug.assert(!stream.is_default);
        if (self.live_streams.remove(stream)) {
            _ = self.driver.cuStreamDestroy_v2(stream.handle);
            self.allocator.destroy(stream);
        } else {
            std.debug.panic("Runtime.destroyStream: unknown stream {*}", .{stream});
        }
    }

    pub fn createEvent(self: *Runtime) Error!*Event {
        const event = self.allocator.create(Event) catch return Error.CudaOutOfMemory;
        errdefer self.allocator.destroy(event);

        var handle: CUevent = null;
        try self.driver.fromResult(self.driver.cuEventCreate(&handle, 0));

        event.* = .{ .runtime = self, .handle = handle };
        return event;
    }

    pub fn destroyEvent(self: *Runtime, event: *Event) void {
        _ = self.driver.cuEventDestroy_v2(event.handle);
        self.allocator.destroy(event);
    }

    pub fn recordGraph(self: *Runtime, dispatches: []const GraphDispatch, failed_index: *?usize) Error!Graph {
        failed_index.* = null;
        const api = driver_mod.GraphApi.load(&self.driver) orelse return error.CudaNotSupported;
        const begin = api.cuStreamBeginCapture_v2;
        const end = api.cuStreamEndCapture;
        const instantiate = api.cuGraphInstantiateWithFlags;
        const destroy_graph = api.cuGraphDestroy;
        std.debug.assert(dispatches.len > 0);

        const stream = try self.createStream();
        defer self.destroyStream(stream);
        try self.driver.fromResult(begin(stream.handle, 0));
        var capturing = true;
        errdefer if (capturing) {
            var abandoned: CUgraph = null;
            if (end(stream.handle, &abandoned) == .success and abandoned != null) {
                _ = destroy_graph(abandoned);
            }
        };
        for (dispatches, 0..) |dispatch, index| {
            failed_index.* = index;
            try dispatch.kernel.launchOnStream(
                stream,
                dispatch.grid,
                dispatch.block,
                dispatch.shared_mem_bytes,
                dispatch.args,
            );
        }
        var graph: CUgraph = null;
        failed_index.* = null;
        try self.driver.fromResult(end(stream.handle, &graph));
        capturing = false;
        defer _ = destroy_graph(graph);
        var exec_handle: CUgraphExec = null;
        try self.driver.fromResult(instantiate(&exec_handle, graph, 0));
        return .{ .runtime = self, .api = api, .handle = exec_handle };
    }
};

pub const GraphDispatch = struct {
    kernel: Kernel,
    grid: [3]u32,
    block: [3]u32,
    shared_mem_bytes: u32,
    args: []const KernelArg,
};

pub const Graph = struct {
    runtime: *Runtime,
    api: driver_mod.GraphApi,
    handle: CUgraphExec,

    pub fn launch(self: *Graph, stream: *Stream) Error!void {
        if (stream.poisoned) return error.CudaStreamPoisoned;
        self.runtime.driver.fromResult(self.api.cuGraphLaunch(self.handle, stream.handle)) catch |err| {
            stream.poisoned = true;
            return err;
        };
    }

    /// The executable may be pending on any stream used for replay.
    pub fn deinit(self: *Graph) void {
        self.runtime.synchronize() catch @panic("CUDA graph destruction requires completion");
        _ = self.api.cuGraphExecDestroy(self.handle);
        self.* = undefined;
    }
};

fn queryDevice(drv: *const Driver, handle: CUdevice) Error!Device {
    var device = Device{ .handle = handle };
    try drv.fromResult(drv.cuDeviceGetName(device.name_buf[0..].ptr, @intCast(device.name_buf.len), handle));
    const name_len = std.mem.indexOfScalar(u8, device.name_buf[0..], 0) orelse device.name_buf.len;
    device.name_len = @intCast(@min(name_len, std.math.maxInt(u8)));

    var major: c_int = 0;
    var minor: c_int = 0;
    try drv.fromResult(drv.cuDeviceGetAttribute(&major, .compute_capability_major, handle));
    try drv.fromResult(drv.cuDeviceGetAttribute(&minor, .compute_capability_minor, handle));
    device.compute_capability = .{
        .major = @intCast(major),
        .minor = @intCast(minor),
    };

    const base_shared = try queryDeviceU32(drv, handle, .max_shared_memory_per_block);
    device.shared_memory_per_block = base_shared;
    device.shared_memory_per_block_optin = queryDeviceU32OrDefault(
        drv,
        handle,
        .max_shared_memory_per_block_optin,
        base_shared,
    );
    return device;
}

fn queryDeviceU32(drv: *const Driver, handle: CUdevice, attr: CUdevice_attribute) Error!u32 {
    var value: c_int = 0;
    try drv.fromResult(drv.cuDeviceGetAttribute(&value, attr, handle));
    if (value < 0) return Error.CudaInvalidValue;
    return @intCast(value);
}

fn queryDeviceU32OrDefault(
    drv: *const Driver,
    handle: CUdevice,
    attr: CUdevice_attribute,
    default_value: u32,
) u32 {
    return queryDeviceU32(drv, handle, attr) catch default_value;
}

pub const Stream = struct {
    runtime: *Runtime,
    handle: CUstream,
    is_default: bool,
    poisoned: bool,

    pub fn synchronize(self: *Stream) Error!void {
        if (self.poisoned) return Error.CudaStreamPoisoned;
        self.runtime.driver.fromResult(
            self.runtime.driver.cuStreamSynchronize(self.handle),
        ) catch |err| {
            self.poisoned = true;
            return err;
        };
    }

    pub fn query(self: *Stream) Error!bool {
        if (self.poisoned) return Error.CudaStreamPoisoned;
        const r = self.runtime.driver.cuStreamQuery(self.handle);
        if (r == .success) return true;
        if (r == .not_ready) return false;
        self.poisoned = true;
        try self.runtime.driver.fromResult(r);
        unreachable;
    }

    pub fn waitEvent(self: *Stream, event: *Event) Error!void {
        if (self.poisoned) return Error.CudaStreamPoisoned;
        self.runtime.driver.fromResult(
            self.runtime.driver.cuStreamWaitEvent(self.handle, event.handle, 0),
        ) catch |err| {
            self.poisoned = true;
            return err;
        };
    }
};

pub const Event = struct {
    runtime: *Runtime,
    handle: CUevent,

    pub fn record(self: *Event, stream: *Stream) Error!void {
        if (stream.poisoned) return Error.CudaStreamPoisoned;
        self.runtime.driver.fromResult(
            self.runtime.driver.cuEventRecord(self.handle, stream.handle),
        ) catch |err| {
            stream.poisoned = true;
            return err;
        };
    }

    pub fn synchronize(self: *Event) Error!void {
        try self.runtime.driver.fromResult(
            self.runtime.driver.cuEventSynchronize(self.handle),
        );
    }

    pub fn query(self: *Event) Error!bool {
        const r = self.runtime.driver.cuEventQuery(self.handle);
        if (r == .success) return true;
        if (r == .not_ready) return false;
        try self.runtime.driver.fromResult(r);
        unreachable;
    }

    pub fn elapsedMs(self: *Event, start: *Event) Error!f32 {
        var out: f32 = 0;
        try self.runtime.driver.fromResult(
            self.runtime.driver.cuEventElapsedTime(&out, start.handle, self.handle),
        );
        return out;
    }
};

pub const Module = struct {
    runtime: *Runtime,
    handle: CUmodule,
    ptx_hash: u64,
    ptx_bytes: []const u8,
    ref_count: usize,

    pub fn getKernel(self: *Module, kernel_name: [:0]const u8) Error!Kernel {
        var func: CUfunction = null;
        try self.runtime.driver.fromResult(
            self.runtime.driver.cuModuleGetFunction(&func, self.handle, kernel_name.ptr),
        );
        return .{ .module = self, .handle = func, .name = kernel_name };
    }

    pub fn retain(self: *Module) Error!*Module {
        if (self.ref_count == std.math.maxInt(usize)) return Error.CudaOutOfMemory;
        self.ref_count += 1;
        return self;
    }

    pub fn release(self: *Module) void {
        std.debug.assert(self.ref_count != 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;

        const rt = self.runtime;
        _ = rt.driver.cuModuleUnload(self.handle);
        if (rt.module_cache.map.fetchRemove(self.ptx_bytes)) |entry| {
            rt.allocator.free(entry.key);
        }
        rt.allocator.destroy(self);
    }

    pub fn deinit(self: *Module) void {
        self.release();
    }
};

pub const Kernel = struct {
    module: *Module,
    handle: CUfunction,
    name: [:0]const u8,

    pub fn launch(
        self: Kernel,
        grid: [3]u32,
        block: [3]u32,
        shared_mem_bytes: u32,
        args: []const KernelArg,
    ) Error!void {
        try self.launchImpl(null, grid, block, shared_mem_bytes, args);
    }

    pub fn launchOnStream(
        self: Kernel,
        stream: *Stream,
        grid: [3]u32,
        block: [3]u32,
        shared_mem_bytes: u32,
        args: []const KernelArg,
    ) Error!void {
        if (stream.poisoned) return Error.CudaStreamPoisoned;
        try self.launchImpl(stream, grid, block, shared_mem_bytes, args);
    }

    fn launchImpl(
        self: Kernel,
        stream: ?*Stream,
        grid: [3]u32,
        block: [3]u32,
        shared_mem_bytes: u32,
        args: []const KernelArg,
    ) Error!void {
        var storage: [max_kernel_args]KernelArgStorage = undefined;
        var params: [max_kernel_args]?*anyopaque = undefined;
        if (args.len > max_kernel_args) return Error.CudaInvalidValue;

        for (args, 0..) |arg, i| {
            storage[i] = KernelArgStorage.from(arg);
            params[i] = @ptrCast(&storage[i].bytes);
        }

        const drv = &self.module.runtime.driver;
        try self.configureDynamicSharedMemory(shared_mem_bytes);
        drv.fromResult(drv.cuLaunchKernel(
            self.handle,
            grid[0],
            grid[1],
            grid[2],
            block[0],
            block[1],
            block[2],
            shared_mem_bytes,
            if (stream) |s| s.handle else null,
            params[0..args.len].ptr,
            null,
        )) catch |err| {
            if (stream) |s| s.poisoned = true;
            return err;
        };
    }

    fn configureDynamicSharedMemory(self: Kernel, shared_mem_bytes: u32) Error!void {
        const device = &self.module.runtime.device;
        if (shared_mem_bytes <= device.shared_memory_per_block) return;
        if (shared_mem_bytes > device.shared_memory_per_block_optin) return Error.CudaInvalidValue;
        try self.module.runtime.driver.fromResult(self.module.runtime.driver.cuFuncSetAttribute(
            self.handle,
            .max_dynamic_shared_size_bytes,
            std.math.cast(c_int, shared_mem_bytes) orelse return Error.CudaInvalidValue,
        ));
    }
};

pub const max_kernel_args: usize = 32;

pub const KernelArg = union(enum) {
    i32: i32,
    u32: u32,
    i64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    device_ptr: CUdeviceptr,
};

const KernelArgStorage = extern struct {
    bytes: [8]u8 align(8),

    fn from(arg: KernelArg) KernelArgStorage {
        var out: KernelArgStorage = .{ .bytes = @as([8]u8, @splat(0)) };
        switch (arg) {
            .i32 => |v| std.mem.writeInt(i32, out.bytes[0..4], v, .little),
            .u32 => |v| std.mem.writeInt(u32, out.bytes[0..4], v, .little),
            .i64 => |v| std.mem.writeInt(i64, out.bytes[0..8], v, .little),
            .u64 => |v| std.mem.writeInt(u64, out.bytes[0..8], v, .little),
            .f32 => |v| std.mem.writeInt(u32, out.bytes[0..4], @bitCast(v), .little),
            .f64 => |v| std.mem.writeInt(u64, out.bytes[0..8], @bitCast(v), .little),
            .device_ptr => |v| std.mem.writeInt(u64, out.bytes[0..8], v, .little),
        }
        return out;
    }
};

pub const ModuleCache = struct {
    map: std.StringHashMapUnmanaged(*Module) = .{},

    pub fn loadPtx(self: *ModuleCache, runtime: *Runtime, ptx: []const u8) Error!*Module {
        if (self.map.get(ptx)) |existing| return try existing.retain();

        const key = runtime.allocator.dupe(u8, ptx) catch return Error.CudaOutOfMemory;
        errdefer runtime.allocator.free(key);
        const ptx_z = runtime.allocator.dupeSentinel(u8, ptx, 0) catch return Error.CudaOutOfMemory;
        defer runtime.allocator.free(ptx_z);

        var handle: CUmodule = null;
        try loadPtxWithJitLog(runtime, &handle, ptx_z.ptr);
        errdefer _ = runtime.driver.cuModuleUnload(handle);

        const module = runtime.allocator.create(Module) catch return Error.CudaOutOfMemory;
        errdefer runtime.allocator.destroy(module);
        module.* = .{
            .runtime = runtime,
            .handle = handle,
            .ptx_hash = std.hash.XxHash3.hash(0, ptx),
            .ptx_bytes = key,
            .ref_count = 1,
        };

        self.map.put(runtime.allocator, key, module) catch return Error.CudaOutOfMemory;
        return module;
    }

    pub fn deinit(self: *ModuleCache, runtime: *Runtime) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const module = entry.value_ptr.*;
            _ = runtime.driver.cuModuleUnload(module.handle);
            runtime.allocator.destroy(module);
            runtime.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit(runtime.allocator);
        self.* = .{};
    }
};

const jit_log_bytes: usize = 16 * 1024;

fn loadPtxWithJitLog(runtime: *Runtime, out: *CUmodule, image: [*]const u8) Error!void {
    var info_log = @as([jit_log_bytes]u8, @splat(0));
    var error_log = @as([jit_log_bytes]u8, @splat(0));
    var options = [_]CUjit_option{
        .info_log_buffer,
        .info_log_buffer_size_bytes,
        .error_log_buffer,
        .error_log_buffer_size_bytes,
        .log_verbose,
    };
    var option_values = [_]?*anyopaque{
        @ptrCast(&info_log[0]),
        @ptrFromInt(info_log.len),
        @ptrCast(&error_log[0]),
        @ptrFromInt(error_log.len),
        @ptrFromInt(1),
    };

    const result = runtime.driver.cuModuleLoadDataEx(
        out,
        image,
        @intCast(options.len),
        &options,
        &option_values,
    );
    emitJitLog(result, &info_log, &error_log);
    try runtime.driver.fromResult(result);
}

fn emitJitLog(result: CUresult, info_log: []const u8, error_log: []const u8) void {
    const error_text = logText(error_log);
    if (error_text.len != 0) {
        log.err("CUDA PTX JIT {s}: {s}", .{ @tagName(result), error_text });
    }
    const failure_text = ptxLoadFailureText(result);
    if (failure_text.len != 0) {
        log.err("CUDA PTX JIT {s}: {s}", .{ @tagName(result), failure_text });
    }
    const info_text = logText(info_log);
    if (info_text.len != 0) {
        log.debug("CUDA PTX JIT {s}: {s}", .{ @tagName(result), info_text });
    }
}

fn ptxLoadFailureText(result: CUresult) []const u8 {
    return switch (result) {
        .jit_compiler_not_found => "NVIDIA driver PTX JIT compiler unavailable; fix the installed driver runtime, not CUDA Toolkit compilers",
        .unsupported_ptx_version => "NVIDIA driver PTX JIT does not support the generated PTX version; lower the PTX target or upgrade the driver runtime",
        else => "",
    };
}

fn logText(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return std.mem.trim(u8, bytes[0..end], " \t\r\n");
}

pub const DeviceBuffer = struct {
    runtime: *Runtime,
    ptr: CUdeviceptr,
    bytes: usize,

    pub fn alloc(runtime: *Runtime, bytes: usize) Error!DeviceBuffer {
        if (bytes == 0) return Error.CudaInvalidValue;
        var ptr: CUdeviceptr = 0;
        try runtime.driver.fromResult(runtime.driver.cuMemAlloc_v2(&ptr, bytes));
        return .{ .runtime = runtime, .ptr = ptr, .bytes = bytes };
    }

    pub fn deinit(self: *DeviceBuffer) void {
        _ = self.runtime.driver.cuMemFree_v2(self.ptr);
        self.* = undefined;
    }

    pub fn copyFromHost(self: *DeviceBuffer, host: []const u8) Error!void {
        if (host.len > self.bytes) return Error.CudaInvalidValue;
        try self.runtime.driver.fromResult(
            self.runtime.driver.cuMemcpyHtoD_v2(self.ptr, host.ptr, host.len),
        );
    }

    pub fn fillWords(self: *DeviceBuffer, pattern: u32) Error!void {
        if (self.bytes % @sizeOf(u32) != 0) return Error.CudaInvalidValue;
        try self.runtime.driver.fromResult(
            self.runtime.driver.cuMemsetD32_v2(self.ptr, pattern, self.bytes / @sizeOf(u32)),
        );
    }

    pub fn copyToHost(self: *DeviceBuffer, host: []u8) Error!void {
        if (host.len < self.bytes) return Error.CudaInvalidValue;
        try self.runtime.driver.fromResult(
            self.runtime.driver.cuMemcpyDtoH_v2(host.ptr, self.ptr, self.bytes),
        );
    }
};

comptime {
    if (@alignOf(KernelArgStorage) < 8) {
        @compileError("KernelArgStorage must be at least 8-byte aligned for the CUDA ABI");
    }
}
const FakeState = struct {
    module_loads: u32 = 0,
    module_load_data_ex_calls: u32 = 0,
    module_unloads: u32 = 0,
    last_ptx_ptr: ?[*]const u8 = null,
    last_jit_option_count: c_uint = 0,
    last_jit_options: [8]CUjit_option = undefined,
    module_load_return: CUresult = .success,
    next_module_handle: usize = 0x1000,

    mem_allocs: u32 = 0,
    mem_frees: u32 = 0,
    last_alloc_bytes: usize = 0,
    last_freed_ptr: CUdeviceptr = 0,
    mem_alloc_return: CUresult = .success,
    next_device_ptr: CUdeviceptr = 0xdead_beef_0000,

    htod_calls: u32 = 0,
    dtoh_calls: u32 = 0,
    last_htod_dst: CUdeviceptr = 0,
    last_htod_bytes: usize = 0,
    last_dtoh_src: CUdeviceptr = 0,
    last_dtoh_bytes: usize = 0,

    sync_calls: u32 = 0,

    launch_calls: u32 = 0,
    last_launch_grid: [3]c_uint = .{ 0, 0, 0 },
    last_launch_block: [3]c_uint = .{ 0, 0, 0 },
    last_launch_shared: c_uint = 0,
    last_launch_stream: CUstream = null,
    launch_return: CUresult = .success,
    expected_arg_count: usize = 0,
    captured_args: [max_kernel_args][8]u8 = undefined,
    func_attribute_calls: u32 = 0,
    last_func_attribute: CUfunction_attribute = .max_dynamic_shared_size_bytes,
    last_func_attribute_value: c_int = 0,
    func_attribute_return: CUresult = .success,

    stream_creates: u32 = 0,
    stream_destroys: u32 = 0,
    stream_syncs: u32 = 0,
    stream_queries: u32 = 0,
    stream_wait_events: u32 = 0,
    stream_create_return: CUresult = .success,
    stream_sync_return: CUresult = .success,
    stream_query_return: CUresult = .success,
    next_stream_handle: usize = 0x7000,

    event_creates: u32 = 0,
    event_destroys: u32 = 0,
    event_records: u32 = 0,
    event_syncs: u32 = 0,
    event_queries: u32 = 0,
    event_elapsed_calls: u32 = 0,
    event_create_return: CUresult = .success,
    event_query_return: CUresult = .success,
    event_elapsed_return_ms: f32 = 0.0,
    next_event_handle: usize = 0x9000,

    fn reset(self: *FakeState) void {
        self.* = .{};
    }
};

var fake: FakeState = .{};

fn fakeCuInit(_: c_uint) callconv(.c) CUresult {
    return .success;
}

fn fakeCuDriverGetVersion(out: *c_int) callconv(.c) CUresult {
    out.* = 12080;
    return .success;
}

fn fakeCuDeviceGetCount(out: *c_int) callconv(.c) CUresult {
    out.* = 1;
    return .success;
}

fn fakeCuDeviceGet(out: *CUdevice, _: c_int) callconv(.c) CUresult {
    out.* = 0;
    return .success;
}

fn fakeCuDeviceGetName(out: [*]u8, len: c_int, _: CUdevice) callconv(.c) CUresult {
    if (len <= 0) return .invalid_value;
    const name = "fake cuda";
    const max_len: usize = @intCast(len - 1);
    const count = @min(name.len, max_len);
    @memcpy(out[0..count], name[0..count]);
    out[count] = 0;
    return .success;
}

fn fakeCuDeviceGetAttribute(out: *c_int, attr: CUdevice_attribute, _: CUdevice) callconv(.c) CUresult {
    out.* = switch (attr) {
        .max_shared_memory_per_block => 48 * 1024,
        .compute_capability_major => 8,
        .compute_capability_minor => 0,
        .max_shared_memory_per_block_optin => 100 * 1024,
        else => return .invalid_value,
    };
    return .success;
}

fn fakeCuCtxCreate(out: *CUcontext, _: c_uint, _: CUdevice) callconv(.c) CUresult {
    out.* = @ptrFromInt(0x1234_0000);
    return .success;
}

fn fakeCuCtxDestroy(_: CUcontext) callconv(.c) CUresult {
    return .success;
}

fn fakeCuCtxSynchronize() callconv(.c) CUresult {
    fake.sync_calls += 1;
    return .success;
}

fn fakeCuModuleLoadData(out: *CUmodule, image: [*]const u8) callconv(.c) CUresult {
    fake.module_loads += 1;
    fake.last_ptx_ptr = image;
    if (fake.module_load_return != .success) return fake.module_load_return;
    fake.next_module_handle += 0x10;
    out.* = @ptrFromInt(fake.next_module_handle);
    return .success;
}

fn fakeCuModuleLoadDataEx(
    out: *CUmodule,
    image: [*]const u8,
    num_options: c_uint,
    options: [*]const CUjit_option,
    _: [*]?*anyopaque,
) callconv(.c) CUresult {
    fake.module_load_data_ex_calls += 1;
    fake.last_jit_option_count = num_options;
    var i: usize = 0;
    while (i < num_options and i < fake.last_jit_options.len) : (i += 1) {
        fake.last_jit_options[i] = options[i];
    }
    return fakeCuModuleLoadData(out, image);
}

fn fakeCuModuleUnload(_: CUmodule) callconv(.c) CUresult {
    fake.module_unloads += 1;
    return .success;
}

fn fakeCuModuleGetFunction(out: *CUfunction, _: CUmodule, _: [*:0]const u8) callconv(.c) CUresult {
    out.* = @ptrFromInt(0xfeed_0000);
    return .success;
}

fn fakeCuFuncSetAttribute(_: CUfunction, attrib: CUfunction_attribute, value: c_int) callconv(.c) CUresult {
    fake.func_attribute_calls += 1;
    fake.last_func_attribute = attrib;
    fake.last_func_attribute_value = value;
    return fake.func_attribute_return;
}

fn fakeCuMemAlloc(out: *CUdeviceptr, bytes: usize) callconv(.c) CUresult {
    fake.mem_allocs += 1;
    fake.last_alloc_bytes = bytes;
    if (fake.mem_alloc_return != .success) return fake.mem_alloc_return;
    fake.next_device_ptr += 0x100;
    out.* = fake.next_device_ptr;
    return .success;
}

fn fakeCuMemFree(ptr: CUdeviceptr) callconv(.c) CUresult {
    fake.mem_frees += 1;
    fake.last_freed_ptr = ptr;
    return .success;
}

fn fakeCuMemcpyHtoD(dst: CUdeviceptr, _: [*]const u8, bytes: usize) callconv(.c) CUresult {
    fake.htod_calls += 1;
    fake.last_htod_dst = dst;
    fake.last_htod_bytes = bytes;
    return .success;
}

fn fakeCuMemcpyDtoH(_: [*]u8, src: CUdeviceptr, bytes: usize) callconv(.c) CUresult {
    fake.dtoh_calls += 1;
    fake.last_dtoh_src = src;
    fake.last_dtoh_bytes = bytes;
    return .success;
}

fn fakeCuLaunchKernel(
    _: CUfunction,
    gx: c_uint,
    gy: c_uint,
    gz: c_uint,
    bx: c_uint,
    by: c_uint,
    bz: c_uint,
    shared_mem_bytes: c_uint,
    stream: CUstream,
    kernel_params: ?[*]?*anyopaque,
    _: ?[*]?*anyopaque,
) callconv(.c) CUresult {
    fake.launch_calls += 1;
    fake.last_launch_grid = .{ gx, gy, gz };
    fake.last_launch_block = .{ bx, by, bz };
    fake.last_launch_shared = shared_mem_bytes;
    fake.last_launch_stream = stream;
    if (kernel_params) |params| {
        var i: usize = 0;
        while (i < fake.expected_arg_count) : (i += 1) {
            const slot: *const [8]u8 = @ptrCast(@alignCast(params[i].?));
            fake.captured_args[i] = slot.*;
        }
    }
    return fake.launch_return;
}

fn fakeCuGetErrorName(_: CUresult, out: *[*:0]const u8) callconv(.c) CUresult {
    out.* = "FAKE";
    return .success;
}

fn fakeCuGetErrorString(_: CUresult, out: *[*:0]const u8) callconv(.c) CUresult {
    out.* = "fake error";
    return .success;
}

fn fakeCuStreamCreate(out: *CUstream, _: c_uint) callconv(.c) CUresult {
    fake.stream_creates += 1;
    if (fake.stream_create_return != .success) return fake.stream_create_return;
    fake.next_stream_handle += 0x10;
    out.* = @ptrFromInt(fake.next_stream_handle);
    return .success;
}

fn fakeCuStreamDestroy(_: CUstream) callconv(.c) CUresult {
    fake.stream_destroys += 1;
    return .success;
}

fn fakeCuStreamSynchronize(_: CUstream) callconv(.c) CUresult {
    fake.stream_syncs += 1;
    return fake.stream_sync_return;
}

fn fakeCuStreamQuery(_: CUstream) callconv(.c) CUresult {
    fake.stream_queries += 1;
    return fake.stream_query_return;
}

fn fakeCuStreamWaitEvent(_: CUstream, _: CUevent, _: c_uint) callconv(.c) CUresult {
    fake.stream_wait_events += 1;
    return .success;
}

fn fakeCuEventCreate(out: *CUevent, _: c_uint) callconv(.c) CUresult {
    fake.event_creates += 1;
    if (fake.event_create_return != .success) return fake.event_create_return;
    fake.next_event_handle += 0x10;
    out.* = @ptrFromInt(fake.next_event_handle);
    return .success;
}

fn fakeCuEventDestroy(_: CUevent) callconv(.c) CUresult {
    fake.event_destroys += 1;
    return .success;
}

fn fakeCuEventRecord(_: CUevent, _: CUstream) callconv(.c) CUresult {
    fake.event_records += 1;
    return .success;
}

fn fakeCuEventSynchronize(_: CUevent) callconv(.c) CUresult {
    fake.event_syncs += 1;
    return .success;
}

fn fakeCuEventQuery(_: CUevent) callconv(.c) CUresult {
    fake.event_queries += 1;
    return fake.event_query_return;
}

fn fakeCuEventElapsedTime(out_ms: *f32, _: CUevent, _: CUevent) callconv(.c) CUresult {
    fake.event_elapsed_calls += 1;
    out_ms.* = fake.event_elapsed_return_ms;
    return .success;
}

fn makeFakeDriver() Driver {
    var drv: Driver = undefined;
    drv.cuInit = fakeCuInit;
    drv.cuDriverGetVersion = fakeCuDriverGetVersion;
    drv.cuDeviceGetCount = fakeCuDeviceGetCount;
    drv.cuDeviceGet = fakeCuDeviceGet;
    drv.cuDeviceGetName = fakeCuDeviceGetName;
    drv.cuDeviceGetAttribute = fakeCuDeviceGetAttribute;
    drv.cuCtxCreate_v2 = fakeCuCtxCreate;
    drv.cuCtxDestroy_v2 = fakeCuCtxDestroy;
    drv.cuCtxSynchronize = fakeCuCtxSynchronize;
    drv.cuModuleLoadData = fakeCuModuleLoadData;
    drv.cuModuleLoadDataEx = fakeCuModuleLoadDataEx;
    drv.cuModuleUnload = fakeCuModuleUnload;
    drv.cuModuleGetFunction = fakeCuModuleGetFunction;
    drv.cuFuncSetAttribute = fakeCuFuncSetAttribute;
    drv.cuMemAlloc_v2 = fakeCuMemAlloc;
    drv.cuMemFree_v2 = fakeCuMemFree;
    drv.cuMemcpyHtoD_v2 = fakeCuMemcpyHtoD;
    drv.cuMemcpyDtoH_v2 = fakeCuMemcpyDtoH;
    drv.cuLaunchKernel = fakeCuLaunchKernel;
    drv.cuGetErrorName = fakeCuGetErrorName;
    drv.cuGetErrorString = fakeCuGetErrorString;
    drv.cuStreamCreate = fakeCuStreamCreate;
    drv.cuStreamDestroy_v2 = fakeCuStreamDestroy;
    drv.cuStreamSynchronize = fakeCuStreamSynchronize;
    drv.cuStreamQuery = fakeCuStreamQuery;
    drv.cuStreamWaitEvent = fakeCuStreamWaitEvent;
    drv.cuEventCreate = fakeCuEventCreate;
    drv.cuEventDestroy_v2 = fakeCuEventDestroy;
    drv.cuEventRecord = fakeCuEventRecord;
    drv.cuEventSynchronize = fakeCuEventSynchronize;
    drv.cuEventQuery = fakeCuEventQuery;
    drv.cuEventElapsedTime = fakeCuEventElapsedTime;
    return drv;
}

fn makeFakeRuntime(allocator: std.mem.Allocator) Runtime {
    return .{
        .allocator = allocator,
        .driver = makeFakeDriver(),
        .ctx = @ptrFromInt(0x1234_0000),
        .device = .{
            .handle = 0,
            .name_buf = fakeDeviceNameBuffer(),
            .name_len = 9,
            .compute_capability = .{ .major = 8, .minor = 0 },
            .shared_memory_per_block = 48 * 1024,
            .shared_memory_per_block_optin = 100 * 1024,
        },
        .module_cache = .{},
        .default_stream_cached = null,
        .live_streams = .{},
    };
}

fn fakeDeviceNameBuffer() [256]u8 {
    var buffer = @as([256]u8, @splat(0));
    @memcpy(buffer[0.."fake cuda".len], "fake cuda");
    return buffer;
}

pub const testing = if (builtin.is_test) struct {
    pub const FakeSnapshot = struct {
        module_loads: u32,
        module_load_data_ex_calls: u32,
        module_unloads: u32,
        mem_allocs: u32,
        mem_frees: u32,
        last_freed_ptr: CUdeviceptr,
        event_elapsed_calls: u32,
    };

    pub fn resetFake() void {
        fake.reset();
    }

    pub fn fakeRuntime(allocator: std.mem.Allocator) Runtime {
        return makeFakeRuntime(allocator);
    }

    pub fn snapshot() FakeSnapshot {
        return .{
            .module_loads = fake.module_loads,
            .module_load_data_ex_calls = fake.module_load_data_ex_calls,
            .module_unloads = fake.module_unloads,
            .mem_allocs = fake.mem_allocs,
            .mem_frees = fake.mem_frees,
            .last_freed_ptr = fake.last_freed_ptr,
            .event_elapsed_calls = fake.event_elapsed_calls,
        };
    }

    pub fn setFakeEventElapsedMs(ms: f32) void {
        fake.event_elapsed_return_ms = ms;
    }
} else struct {};

test "ModuleCache hit returns the cached pointer and does not reload" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const ptx: []const u8 = "fake ptx bytes";
    const first = try rt.loadPtx(ptx);
    try std.testing.expectEqual(@as(u32, 1), fake.module_loads);
    try std.testing.expectEqual(@as(u32, 1), fake.module_load_data_ex_calls);
    try std.testing.expectEqual(@as(c_uint, 5), fake.last_jit_option_count);
    try std.testing.expectEqual(CUjit_option.info_log_buffer, fake.last_jit_options[0]);
    try std.testing.expectEqual(CUjit_option.info_log_buffer_size_bytes, fake.last_jit_options[1]);
    try std.testing.expectEqual(CUjit_option.error_log_buffer, fake.last_jit_options[2]);
    try std.testing.expectEqual(CUjit_option.error_log_buffer_size_bytes, fake.last_jit_options[3]);
    try std.testing.expectEqual(CUjit_option.log_verbose, fake.last_jit_options[4]);

    const second = try rt.loadPtx(ptx);
    try std.testing.expectEqual(@as(u32, 1), fake.module_loads);
    try std.testing.expectEqual(@as(u32, 1), fake.module_load_data_ex_calls);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first.ptx_hash, second.ptx_hash);
    try std.testing.expectEqualStrings(ptx, second.ptx_bytes);
    try std.testing.expectEqual(@as(usize, 2), second.ref_count);
}

test "ModuleCache miss on different PTX triggers a second load" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod_a = try rt.loadPtx("ptx program A");
    const mod_b = try rt.loadPtx("ptx program B");
    try std.testing.expectEqual(@as(u32, 2), fake.module_loads);
    try std.testing.expectEqual(@as(u32, 2), fake.module_load_data_ex_calls);
    try std.testing.expect(mod_a != mod_b);
    try std.testing.expect(mod_a.ptx_hash != mod_b.ptx_hash);
    try std.testing.expectEqualStrings("ptx program A", mod_a.ptx_bytes);
    try std.testing.expectEqualStrings("ptx program B", mod_b.ptx_bytes);
}

test "Module.release unloads cached PTX after final reference" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const first = try rt.loadPtx("shared ptx");
    const second = try rt.loadPtx("shared ptx");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), second.ref_count);

    first.release();
    try std.testing.expectEqual(@as(u32, 0), fake.module_unloads);
    try std.testing.expectEqual(@as(usize, 1), second.ref_count);

    const third = try rt.loadPtx("shared ptx");
    try std.testing.expectEqual(second, third);
    try std.testing.expectEqual(@as(usize, 2), third.ref_count);

    second.release();
    try std.testing.expectEqual(@as(u32, 0), fake.module_unloads);
    third.release();
    try std.testing.expectEqual(@as(u32, 1), fake.module_unloads);
    try std.testing.expectEqual(@as(usize, 0), rt.module_cache.map.count());
}

test "ModuleCache.deinit unloads every cached module exactly once" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);

    _ = try rt.loadPtx("ptx one");
    _ = try rt.loadPtx("ptx two");
    _ = try rt.loadPtx("ptx three");
    try std.testing.expectEqual(@as(u32, 3), fake.module_loads);
    try std.testing.expectEqual(@as(u32, 0), fake.module_unloads);

    rt.module_cache.deinit(&rt);
    try std.testing.expectEqual(@as(u32, 3), fake.module_unloads);
}

test "ModuleCache.loadPtx surfaces driver errors as typed Error values" {
    fake.reset();
    fake.module_load_return = .invalid_ptx;
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    try std.testing.expectError(Error.CudaInvalidPtx, rt.loadPtx("garbage ptx"));
    try std.testing.expectEqual(@as(u32, 1), fake.module_loads);
    try std.testing.expectEqual(@as(u32, 1), fake.module_load_data_ex_calls);
    try std.testing.expectEqual(@as(u32, 0), fake.module_unloads);
}

test "ptxLoadFailureText identifies driver PTX compatibility failures" {
    const missing_jit = ptxLoadFailureText(.jit_compiler_not_found);
    try std.testing.expect(std.mem.indexOf(u8, missing_jit, "NVIDIA driver PTX JIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_jit, "CUDA Toolkit") != null);

    const unsupported = ptxLoadFailureText(.unsupported_ptx_version);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "driver PTX JIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "generated PTX version") != null);

    try std.testing.expectEqualStrings("", ptxLoadFailureText(.success));
}

test "DeviceBuffer.alloc rejects zero bytes before calling the driver" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);

    try std.testing.expectError(Error.CudaInvalidValue, DeviceBuffer.alloc(&rt, 0));
    try std.testing.expectEqual(@as(u32, 0), fake.mem_allocs);
}

test "DeviceBuffer full lifecycle: alloc, copyFromHost, copyToHost, deinit" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);

    var buf = try DeviceBuffer.alloc(&rt, 128);
    try std.testing.expectEqual(@as(u32, 1), fake.mem_allocs);
    try std.testing.expectEqual(@as(usize, 128), fake.last_alloc_bytes);
    try std.testing.expectEqual(@as(usize, 128), buf.bytes);
    try std.testing.expect(buf.ptr != 0);

    const host_in = @as([128]u8, @splat(0xab));
    try buf.copyFromHost(&host_in);
    try std.testing.expectEqual(@as(u32, 1), fake.htod_calls);
    try std.testing.expectEqual(buf.ptr, fake.last_htod_dst);
    try std.testing.expectEqual(@as(usize, 128), fake.last_htod_bytes);

    var host_out: [128]u8 = undefined;
    try buf.copyToHost(&host_out);
    try std.testing.expectEqual(@as(u32, 1), fake.dtoh_calls);
    try std.testing.expectEqual(buf.ptr, fake.last_dtoh_src);
    try std.testing.expectEqual(@as(usize, 128), fake.last_dtoh_bytes);

    const owned_ptr = buf.ptr;
    buf.deinit();
    try std.testing.expectEqual(@as(u32, 1), fake.mem_frees);
    try std.testing.expectEqual(owned_ptr, fake.last_freed_ptr);
}

test "DeviceBuffer.copyFromHost rejects a host slice larger than the buffer" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);

    var buf = try DeviceBuffer.alloc(&rt, 16);
    defer buf.deinit();

    const oversized = @as([32]u8, @splat(0));
    try std.testing.expectError(Error.CudaInvalidValue, buf.copyFromHost(&oversized));
    try std.testing.expectEqual(@as(u32, 0), fake.htod_calls);
}

test "DeviceBuffer.copyToHost rejects a host slice smaller than the buffer" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);

    var buf = try DeviceBuffer.alloc(&rt, 64);
    defer buf.deinit();

    var undersized: [32]u8 = undefined;
    try std.testing.expectError(Error.CudaInvalidValue, buf.copyToHost(&undersized));
    try std.testing.expectEqual(@as(u32, 0), fake.dtoh_calls);
}

test "DeviceBuffer.alloc maps cuMemAlloc_v2 out_of_memory to CudaOutOfMemory" {
    fake.reset();
    fake.mem_alloc_return = .out_of_memory;
    var rt = makeFakeRuntime(std.testing.allocator);

    try std.testing.expectError(Error.CudaOutOfMemory, DeviceBuffer.alloc(&rt, 4096));
    try std.testing.expectEqual(@as(u32, 1), fake.mem_allocs);
    try std.testing.expectEqual(@as(u32, 0), fake.mem_frees);
}

test "Kernel.launch forwards grid, block, and shared_mem_bytes to cuLaunchKernel" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("dummy ptx");
    const kernel = try mod.getKernel("kernel");
    fake.expected_arg_count = 0;
    try kernel.launch(.{ 7, 11, 13 }, .{ 32, 4, 2 }, 256, &.{});

    try std.testing.expectEqual(@as(u32, 1), fake.launch_calls);
    try std.testing.expectEqual([3]c_uint{ 7, 11, 13 }, fake.last_launch_grid);
    try std.testing.expectEqual([3]c_uint{ 32, 4, 2 }, fake.last_launch_block);
    try std.testing.expectEqual(@as(c_uint, 256), fake.last_launch_shared);
    try std.testing.expectEqual(@as(CUstream, null), fake.last_launch_stream);
    try std.testing.expectEqual(@as(u32, 0), fake.func_attribute_calls);
}

test "Kernel.launch opts into dynamic shared memory above the default block limit" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("dynamic shared ptx");
    const kernel = try mod.getKernel("kernel");
    fake.expected_arg_count = 0;
    try kernel.launch(.{ 1, 1, 1 }, .{ 128, 1, 1 }, 64 * 1024, &.{});

    try std.testing.expectEqual(@as(u32, 1), fake.func_attribute_calls);
    try std.testing.expectEqual(CUfunction_attribute.max_dynamic_shared_size_bytes, fake.last_func_attribute);
    try std.testing.expectEqual(@as(c_int, 64 * 1024), fake.last_func_attribute_value);
    try std.testing.expectEqual(@as(u32, 1), fake.launch_calls);
    try std.testing.expectEqual(@as(c_uint, 64 * 1024), fake.last_launch_shared);
}

test "Kernel.launch rejects dynamic shared memory above the opt-in block limit" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("too much dynamic shared ptx");
    const kernel = try mod.getKernel("kernel");
    fake.expected_arg_count = 0;

    try std.testing.expectError(
        Error.CudaInvalidValue,
        kernel.launch(.{ 1, 1, 1 }, .{ 128, 1, 1 }, 128 * 1024, &.{}),
    );
    try std.testing.expectEqual(@as(u32, 0), fake.func_attribute_calls);
    try std.testing.expectEqual(@as(u32, 0), fake.launch_calls);
}

test "Kernel.launch marshals i32 and u32 args into the low four bytes little-endian" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("p32");
    const kernel = try mod.getKernel("k");
    const args = [_]KernelArg{
        .{ .i32 = -2 },
        .{ .u32 = 0x01020304 },
    };
    fake.expected_arg_count = args.len;
    try kernel.launch(.{ 1, 1, 1 }, .{ 1, 1, 1 }, 0, &args);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xFE, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0 },
        &fake.captured_args[0],
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0 },
        &fake.captured_args[1],
    );
}

test "Kernel.launch marshals 64-bit args (u64, i64, device_ptr) across all eight bytes" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("p64");
    const kernel = try mod.getKernel("k");
    const args = [_]KernelArg{
        .{ .u64 = 0x0102030405060708 },
        .{ .i64 = -1 },
        .{ .device_ptr = 0xdead_beef_cafe_f00d },
    };
    fake.expected_arg_count = args.len;
    try kernel.launch(.{ 1, 1, 1 }, .{ 1, 1, 1 }, 0, &args);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 },
        &fake.captured_args[0],
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
        &fake.captured_args[1],
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x0D, 0xF0, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE },
        &fake.captured_args[2],
    );
}

test "Kernel.launch marshals floats by bit-cast, not by value conversion" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("pf");
    const kernel = try mod.getKernel("k");
    const args = [_]KernelArg{
        .{ .f32 = 1.0 },
        .{ .f64 = 2.0 },
    };
    fake.expected_arg_count = args.len;
    try kernel.launch(.{ 1, 1, 1 }, .{ 1, 1, 1 }, 0, &args);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x00, 0x80, 0x3F, 0, 0, 0, 0 },
        &fake.captured_args[0],
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 0, 0, 0, 0x00, 0x40 },
        &fake.captured_args[1],
    );
}

test "Kernel.launch rejects arg counts above max_kernel_args without dispatching" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("pbig");
    const kernel = try mod.getKernel("k");
    const too_many = @as([(max_kernel_args + 1)]KernelArg, @splat(.{ .i32 = 0 }));
    try std.testing.expectError(
        Error.CudaInvalidValue,
        kernel.launch(.{ 1, 1, 1 }, .{ 1, 1, 1 }, 0, &too_many),
    );
    try std.testing.expectEqual(@as(u32, 0), fake.launch_calls);
}

test "Kernel.launchOnStream forwards the provided CUstream to cuLaunchKernel" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);
    defer rt.module_cache.deinit(&rt);

    const mod = try rt.loadPtx("pstream");
    const kernel = try mod.getKernel("k");
    const stream = try rt.createStream();
    defer rt.destroyStream(stream);

    fake.expected_arg_count = 0;
    try kernel.launchOnStream(stream, .{ 3, 1, 1 }, .{ 8, 1, 1 }, 0, &.{});

    try std.testing.expectEqual(@as(u32, 1), fake.launch_calls);
    try std.testing.expectEqual(stream.handle, fake.last_launch_stream);
}

test "Runtime.synchronize dispatches cuCtxSynchronize through the driver" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    try rt.synchronize();
    try std.testing.expectEqual(@as(u32, 1), fake.sync_calls);
}

test "Runtime.createStream allocates a stream and tracks it in live_streams" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const s = try rt.createStream();
    defer rt.destroyStream(s);

    try std.testing.expectEqual(@as(u32, 1), fake.stream_creates);
    try std.testing.expectEqual(@as(usize, 1), rt.live_streams.count());
    try std.testing.expect(!s.is_default);
    try std.testing.expect(s.handle != null);
    try std.testing.expect(rt.live_streams.contains(s));
}

test "Runtime.destroyStream round-trips: live_streams empty, one driver destroy" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const s = try rt.createStream();
    try std.testing.expectEqual(@as(usize, 1), rt.live_streams.count());

    rt.destroyStream(s);

    try std.testing.expectEqual(@as(u32, 1), fake.stream_creates);
    try std.testing.expectEqual(@as(u32, 1), fake.stream_destroys);
    try std.testing.expectEqual(@as(usize, 0), rt.live_streams.count());
}

test "Runtime.createStream surfaces cuStreamCreate errors without leaking" {
    fake.reset();
    fake.stream_create_return = .out_of_memory;
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    try std.testing.expectError(Error.CudaOutOfMemory, rt.createStream());
    try std.testing.expectEqual(@as(u32, 1), fake.stream_creates);
    try std.testing.expectEqual(@as(u32, 0), fake.stream_destroys);
    try std.testing.expectEqual(@as(usize, 0), rt.live_streams.count());
}

test "Runtime.defaultStream is lazy, stable, and not tracked in live_streams" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);
    defer if (rt.default_stream_cached) |s| rt.allocator.destroy(s);

    const s1 = try rt.defaultStream();
    try std.testing.expectEqual(@as(u32, 0), fake.stream_creates);
    try std.testing.expect(s1.is_default);
    try std.testing.expectEqual(@as(CUstream, null), s1.handle);
    try std.testing.expectEqual(@as(usize, 0), rt.live_streams.count());

    const s2 = try rt.defaultStream();
    try std.testing.expectEqual(s1, s2);
}

test "Stream.synchronize dispatches cuStreamSynchronize when not poisoned" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const s = try rt.createStream();
    defer rt.destroyStream(s);

    try s.synchronize();
    try std.testing.expectEqual(@as(u32, 1), fake.stream_syncs);
    try std.testing.expect(!s.poisoned);
}

test "Stream.synchronize poisons the stream on non-OK result" {
    fake.reset();
    fake.stream_sync_return = .launch_failed;
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const s = try rt.createStream();
    defer rt.destroyStream(s);

    try std.testing.expectError(Error.CudaLaunchFailed, s.synchronize());
    try std.testing.expect(s.poisoned);

    fake.stream_syncs = 0;
    try std.testing.expectError(Error.CudaStreamPoisoned, s.synchronize());
    try std.testing.expectEqual(@as(u32, 0), fake.stream_syncs);
}

test "Stream.query maps success/not_ready to bool and poisons on other errors" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const s = try rt.createStream();
    defer rt.destroyStream(s);

    try std.testing.expect(try s.query());

    fake.stream_query_return = .not_ready;
    try std.testing.expect(!try s.query());
    try std.testing.expect(!s.poisoned);

    fake.stream_query_return = .launch_failed;
    try std.testing.expectError(Error.CudaLaunchFailed, s.query());
    try std.testing.expect(s.poisoned);
}

test "Runtime.createEvent and destroyEvent round-trip through the driver" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const e = try rt.createEvent();
    try std.testing.expectEqual(@as(u32, 1), fake.event_creates);
    try std.testing.expect(e.handle != null);

    rt.destroyEvent(e);
    try std.testing.expectEqual(@as(u32, 1), fake.event_destroys);
}

test "Event.record dispatches cuEventRecord and does not poison a healthy stream" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const s = try rt.createStream();
    defer rt.destroyStream(s);
    const e = try rt.createEvent();
    defer rt.destroyEvent(e);

    try e.record(s);
    try std.testing.expectEqual(@as(u32, 1), fake.event_records);
    try std.testing.expect(!s.poisoned);
}

test "Event.synchronize and Event.query dispatch through the driver" {
    fake.reset();
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const e = try rt.createEvent();
    defer rt.destroyEvent(e);

    try e.synchronize();
    try std.testing.expectEqual(@as(u32, 1), fake.event_syncs);

    try std.testing.expect(try e.query());
    fake.event_query_return = .not_ready;
    try std.testing.expect(!try e.query());
}

test "Event.elapsedMs reads the driver's milliseconds-since-start" {
    fake.reset();
    fake.event_elapsed_return_ms = 2.5;
    var rt = makeFakeRuntime(std.testing.allocator);
    defer rt.live_streams.deinit(rt.allocator);

    const start = try rt.createEvent();
    defer rt.destroyEvent(start);
    const end = try rt.createEvent();
    defer rt.destroyEvent(end);

    const ms = try end.elapsedMs(start);
    try std.testing.expectEqual(@as(f32, 2.5), ms);
    try std.testing.expectEqual(@as(u32, 1), fake.event_elapsed_calls);
}
