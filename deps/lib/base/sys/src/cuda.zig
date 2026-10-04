//! CUDA Driver API bindings: ABI types, the dynamically loaded entry points,
//! and `CUresult` mapped to typed errors.

const std = @import("std");
const capabilities = @import("capabilities.zig");
const dynamic = @import("dynamic.zig");

pub const required_capabilities = capabilities.host(&.{ .allocator, .dynamic_loading });

const log = std.log.scoped(.cuda_driver);

pub const CUdevice = i32;

pub const CUdevice_attribute = enum(c_int) {
    max_shared_memory_per_block = 8,
    compute_capability_major = 75,
    compute_capability_minor = 76,
    max_shared_memory_per_block_optin = 97,
    _,
};

pub const CUfunction_attribute = enum(c_int) {
    max_dynamic_shared_size_bytes = 8,
    _,
};

pub const CUcontext = ?*anyopaque;

pub const CUmodule = ?*anyopaque;

pub const CUfunction = ?*anyopaque;

pub const CUdeviceptr = u64;

pub const CUstream = ?*anyopaque;

pub const CUevent = ?*anyopaque;

pub const CUgraph = ?*anyopaque;
pub const CUgraphExec = ?*anyopaque;

pub const CUjit_option = enum(c_int) {
    info_log_buffer = 3,
    info_log_buffer_size_bytes = 4,
    error_log_buffer = 5,
    error_log_buffer_size_bytes = 6,
    log_verbose = 12,
};

pub const CUresult = enum(c_int) {
    success = 0,
    invalid_value = 1,
    out_of_memory = 2,
    not_initialized = 3,
    deinitialized = 4,
    no_device = 100,
    invalid_device = 101,
    invalid_image = 200,
    invalid_context = 201,
    no_binary_for_gpu = 209,
    invalid_ptx = 218,
    jit_compiler_not_found = 221,
    unsupported_ptx_version = 222,
    invalid_source = 300,
    file_not_found = 301,
    shared_object_symbol_not_found = 302,
    shared_object_init_failed = 303,
    invalid_handle = 400,
    not_found = 500,
    not_ready = 600,
    illegal_address = 700,
    launch_out_of_resources = 701,
    launch_timeout = 702,
    launch_incompatible_texturing = 703,
    launch_failed = 719,
    not_supported = 801,
    unknown = 999,
    _,
};

pub const Error = error{
    CudaDriverNotFound,
    CudaSymbolMissing,
    CudaNotInitialized,
    CudaDeinitialized,
    CudaOutOfMemory,
    CudaInvalidValue,
    CudaInvalidContext,
    CudaInvalidImage,
    CudaInvalidHandle,
    CudaInvalidPtx,
    CudaUnsupportedPtxVersion,
    CudaJitCompilerNotFound,
    CudaLaunchFailed,
    CudaLaunchOutOfResources,
    CudaLaunchTimeout,
    CudaLaunchIncompatibleTexturing,
    CudaNoDevice,
    CudaInvalidDevice,
    CudaNoBinaryForGpu,
    CudaIllegalAddress,
    CudaNotSupported,
    CudaSharedObjectSymbolNotFound,
    CudaSharedObjectInitFailed,
    CudaUnknown,
    CudaStreamPoisoned,
};

pub const Driver = struct {
    lib: dynamic.Library,

    cuInit: *const fn (flags: c_uint) callconv(.c) CUresult,
    cuDriverGetVersion: *const fn (out: *c_int) callconv(.c) CUresult,
    cuDeviceGetCount: *const fn (out: *c_int) callconv(.c) CUresult,
    cuDeviceGet: *const fn (out: *CUdevice, ordinal: c_int) callconv(.c) CUresult,
    cuDeviceGetName: *const fn (name: [*]u8, len: c_int, dev: CUdevice) callconv(.c) CUresult,
    cuDeviceGetAttribute: *const fn (out: *c_int, attrib: CUdevice_attribute, dev: CUdevice) callconv(.c) CUresult,
    cuCtxCreate_v2: *const fn (out: *CUcontext, flags: c_uint, dev: CUdevice) callconv(.c) CUresult,
    cuCtxDestroy_v2: *const fn (ctx: CUcontext) callconv(.c) CUresult,
    cuCtxSynchronize: *const fn () callconv(.c) CUresult,
    cuModuleLoadData: *const fn (out: *CUmodule, image: [*]const u8) callconv(.c) CUresult,
    cuModuleLoadDataEx: *const fn (
        out: *CUmodule,
        image: [*]const u8,
        num_options: c_uint,
        options: [*]const CUjit_option,
        option_values: [*]?*anyopaque,
    ) callconv(.c) CUresult,
    cuModuleUnload: *const fn (mod: CUmodule) callconv(.c) CUresult,
    cuModuleGetFunction: *const fn (out: *CUfunction, mod: CUmodule, name: [*:0]const u8) callconv(.c) CUresult,
    cuFuncSetAttribute: *const fn (
        func: CUfunction,
        attrib: CUfunction_attribute,
        value: c_int,
    ) callconv(.c) CUresult,
    cuMemAlloc_v2: *const fn (out: *CUdeviceptr, bytes: usize) callconv(.c) CUresult,
    cuMemFree_v2: *const fn (ptr: CUdeviceptr) callconv(.c) CUresult,
    cuMemcpyHtoD_v2: *const fn (dst: CUdeviceptr, src: [*]const u8, bytes: usize) callconv(.c) CUresult,
    cuMemcpyDtoH_v2: *const fn (dst: [*]u8, src: CUdeviceptr, bytes: usize) callconv(.c) CUresult,
    cuMemsetD32_v2: *const fn (dst: CUdeviceptr, value: c_uint, count: usize) callconv(.c) CUresult,
    cuLaunchKernel: *const fn (
        func: CUfunction,
        grid_x: c_uint,
        grid_y: c_uint,
        grid_z: c_uint,
        block_x: c_uint,
        block_y: c_uint,
        block_z: c_uint,
        shared_mem_bytes: c_uint,
        stream: CUstream,
        kernel_params: ?[*]?*anyopaque,
        extra: ?[*]?*anyopaque,
    ) callconv(.c) CUresult,
    cuGetErrorName: *const fn (res: CUresult, out: *[*:0]const u8) callconv(.c) CUresult,
    cuGetErrorString: *const fn (res: CUresult, out: *[*:0]const u8) callconv(.c) CUresult,

    cuStreamCreate: *const fn (out: *CUstream, flags: c_uint) callconv(.c) CUresult,
    cuStreamDestroy_v2: *const fn (stream: CUstream) callconv(.c) CUresult,
    cuStreamSynchronize: *const fn (stream: CUstream) callconv(.c) CUresult,
    cuStreamQuery: *const fn (stream: CUstream) callconv(.c) CUresult,
    cuStreamWaitEvent: *const fn (stream: CUstream, event: CUevent, flags: c_uint) callconv(.c) CUresult,

    cuEventCreate: *const fn (out: *CUevent, flags: c_uint) callconv(.c) CUresult,
    cuEventDestroy_v2: *const fn (event: CUevent) callconv(.c) CUresult,
    cuEventRecord: *const fn (event: CUevent, stream: CUstream) callconv(.c) CUresult,
    cuEventSynchronize: *const fn (event: CUevent) callconv(.c) CUresult,
    cuEventQuery: *const fn (event: CUevent) callconv(.c) CUresult,
    cuEventElapsedTime: *const fn (out_ms: *f32, start: CUevent, end: CUevent) callconv(.c) CUresult,

    pub fn open(allocator: std.mem.Allocator) Error!Driver {
        _ = allocator;

        var lib = dynamic.openCudaDriver() catch return error.CudaDriverNotFound;
        errdefer lib.close();

        return resolveAll(&lib);
    }

    fn resolveAll(lib: *dynamic.Library) Error!Driver {
        var driver: Driver = undefined;
        driver.lib = lib.*;

        inline for (
            @typeInfo(Driver).@"struct".field_names,
            @typeInfo(Driver).@"struct".field_types,
            @typeInfo(Driver).@"struct".field_attrs,
        ) |field_name, field_name_type, field_name_attrs| {
            const field = .{ .name = field_name, .type = field_name_type, .attrs = field_name_attrs };
            if (comptime std.mem.eql(u8, field.name, "lib")) continue;
            const symbol = lib.lookup(field.type, field.name) orelse {
                log.err("cuda symbol missing: {s}", .{field.name});
                return error.CudaSymbolMissing;
            };
            @field(driver, field.name) = symbol;
        }

        return driver;
    }

    pub fn close(self: *Driver) void {
        self.lib.close();
    }

    pub fn fromResult(self: *const Driver, r: CUresult) Error!void {
        if (r == .success) return;

        const err = switch (r) {
            .success => unreachable,
            .invalid_value => Error.CudaInvalidValue,
            .out_of_memory => Error.CudaOutOfMemory,
            .not_initialized => Error.CudaNotInitialized,
            .deinitialized => Error.CudaDeinitialized,
            .no_device => Error.CudaNoDevice,
            .invalid_device => Error.CudaInvalidDevice,
            .invalid_image => Error.CudaInvalidImage,
            .invalid_context => Error.CudaInvalidContext,
            .no_binary_for_gpu => Error.CudaNoBinaryForGpu,
            .invalid_ptx => Error.CudaInvalidPtx,
            .jit_compiler_not_found => Error.CudaJitCompilerNotFound,
            .unsupported_ptx_version => Error.CudaUnsupportedPtxVersion,
            .invalid_source => Error.CudaInvalidImage,
            .file_not_found => Error.CudaInvalidImage,
            .shared_object_symbol_not_found => Error.CudaSharedObjectSymbolNotFound,
            .shared_object_init_failed => Error.CudaSharedObjectInitFailed,
            .invalid_handle => Error.CudaInvalidHandle,
            .not_found => Error.CudaInvalidHandle,
            .not_ready => Error.CudaUnknown,
            .illegal_address => Error.CudaIllegalAddress,
            .launch_out_of_resources => Error.CudaLaunchOutOfResources,
            .launch_timeout => Error.CudaLaunchTimeout,
            .launch_incompatible_texturing => Error.CudaLaunchIncompatibleTexturing,
            .launch_failed => Error.CudaLaunchFailed,
            .not_supported => Error.CudaNotSupported,
            .unknown => Error.CudaUnknown,
            _ => unknown: {
                self.logUnknown(r);
                break :unknown Error.CudaUnknown;
            },
        };
        return err;
    }

    fn logUnknown(self: *const Driver, r: CUresult) void {
        var name_ptr: [*:0]const u8 = "";
        var text_ptr: [*:0]const u8 = "";
        _ = self.cuGetErrorName(r, &name_ptr);
        _ = self.cuGetErrorString(r, &text_ptr);
        log.warn("unmapped CUresult {d}: {s} — {s}", .{
            @backingInt(r),
            std.mem.sliceTo(name_ptr, 0),
            std.mem.sliceTo(text_ptr, 0),
        });
    }
};

/// Optional CUDA graph entry points. An older libcuda still opens its base
/// Driver, and only a caller requesting graphs resolves this set.
pub const GraphApi = struct {
    cuStreamBeginCapture_v2: *const fn (stream: CUstream, mode: c_int) callconv(.c) CUresult,
    cuStreamEndCapture: *const fn (stream: CUstream, graph: *CUgraph) callconv(.c) CUresult,
    cuGraphInstantiateWithFlags: *const fn (exec: *CUgraphExec, graph: CUgraph, flags: u64) callconv(.c) CUresult,
    cuGraphLaunch: *const fn (exec: CUgraphExec, stream: CUstream) callconv(.c) CUresult,
    cuGraphExecDestroy: *const fn (exec: CUgraphExec) callconv(.c) CUresult,
    cuGraphDestroy: *const fn (graph: CUgraph) callconv(.c) CUresult,

    pub fn load(driver: *Driver) ?GraphApi {
        const lib = &driver.lib;
        return .{
            .cuStreamBeginCapture_v2 = lib.lookup(@FieldType(GraphApi, "cuStreamBeginCapture_v2"), "cuStreamBeginCapture_v2") orelse return null,
            .cuStreamEndCapture = lib.lookup(@FieldType(GraphApi, "cuStreamEndCapture"), "cuStreamEndCapture") orelse return null,
            .cuGraphInstantiateWithFlags = lib.lookup(@FieldType(GraphApi, "cuGraphInstantiateWithFlags"), "cuGraphInstantiateWithFlags") orelse return null,
            .cuGraphLaunch = lib.lookup(@FieldType(GraphApi, "cuGraphLaunch"), "cuGraphLaunch") orelse return null,
            .cuGraphExecDestroy = lib.lookup(@FieldType(GraphApi, "cuGraphExecDestroy"), "cuGraphExecDestroy") orelse return null,
            .cuGraphDestroy = lib.lookup(@FieldType(GraphApi, "cuGraphDestroy"), "cuGraphDestroy") orelse return null,
        };
    }
};

comptime {
    if (@sizeOf(CUresult) != @sizeOf(c_int)) {
        @compileError("CUresult ABI drift: storage must be c_int");
    }
    if (@sizeOf(CUdevice_attribute) != @sizeOf(c_int)) {
        @compileError("CUdevice_attribute ABI drift: storage must be c_int");
    }
    if (@sizeOf(CUfunction_attribute) != @sizeOf(c_int)) {
        @compileError("CUfunction_attribute ABI drift: storage must be c_int");
    }
    if (@sizeOf(CUdeviceptr) != 8) {
        @compileError("CUdeviceptr must be 64-bit on a 64-bit host");
    }
}

pub fn platformSupported() bool {
    return dynamic.hasHostCandidate(dynamic.cudaDriverCandidates());
}

fn skipIfHostHasDriver() !void {
    if (!platformSupported()) return error.SkipZigTest;
    if (dynamic.isCudaDriverLoadable()) return error.SkipZigTest;
}
