const std = @import("std");
const gpu = @import("gpu");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");

const binding = accy.executable.binding;
const BackendArtifactPlan = accy.artifact.BackendArtifactPlan;
const CompiledFragment = accy.executable.CompiledFragment;
const CpuState = gpu.cpu.State;
const LoadedFragment = accy.executable.LoadedFragment;
const Program = tensor.program.Program;

/// A caller sizes its bookkeeping by this bound on programs held at once: one session holds at most
/// 64 compiled programs at a time. Compiling another program while all 64 are held returns
/// `error.TooManyPrograms`.
pub const max_programs: u32 = 64;

/// A caller matches on these to handle session failures: the set lists every failure a session call
/// can return. Each failure maps to exactly one stable status number.
pub const Error = error{
    InvalidProgram,
    UnsupportedVersion,
    InvalidHandle,
    InvalidBuffer,
    TooManyPrograms,
    OutOfMemory,
    CompileFailed,
    LaunchFailed,
};

/// A host sends these numbers to report failures across a language boundary: the codes run from 0
/// for success to 8 for a failed launch. Once a number is assigned it keeps its meaning for good.
pub const Status = enum(u32) {
    ok = 0,
    invalid_program = 1,
    unsupported_version = 2,
    invalid_handle = 3,
    invalid_buffer = 4,
    too_many_programs = 5,
    out_of_memory = 6,
    compile_failed = 7,
    launch_failed = 8,

    pub fn fromError(err: Error) Status {
        return switch (err) {
            error.InvalidProgram => .invalid_program,
            error.UnsupportedVersion => .unsupported_version,
            error.InvalidHandle => .invalid_handle,
            error.InvalidBuffer => .invalid_buffer,
            error.TooManyPrograms => .too_many_programs,
            error.OutOfMemory => .out_of_memory,
            error.CompileFailed => .compile_failed,
            error.LaunchFailed => .launch_failed,
        };
    }
};

/// A caller keeps this handle to name one compiled program in later calls by slot index and
/// generation count. `Session.release` changes the slot's generation, so every copy of the old
/// handle is refused with `error.InvalidHandle` from then on.
pub const Handle = struct {
    index: u32,
    generation: u32,
};

/// A caller reads these descriptors to size and type the buffers it passes to a run: the value
/// gives the element type, axes, byte length and required alignment of one input or output. `dims`
/// points into the compiled program's own types and stays valid until that program is released.
pub const Descriptor = struct {
    dtype: tensor.DType,
    dims: []const tensor.Dim,
    byte_size: usize,
    alignment: u32,
};

const Entry = struct {
    live: bool = false,
    generation: u32 = 0,
    program: Program = undefined,
    compiled: *const CompiledFragment = undefined,
    fragment: *LoadedFragment = undefined,
    descriptors: []Descriptor = &.{},
    input_count: usize = 0,
};

/// A host creates a session to compile tensor programs for the CPU backend inside this process and
/// run them on memory it supplies. The session runs programs forward only, with no transform that
/// computes derivatives.
pub const Session = struct {
    allocator: std.mem.Allocator,
    cpu: *CpuState,
    entries: [max_programs]Entry = @splat(.{}),
    /// A caller reads this field to log why the last failing call failed: the field holds the inner
    /// error behind the most recent failure that went through the session's error mapping, and it
    /// is for diagnostics only. Failures returned directly, such as a full table, a stale handle, a
    /// buffer count mismatch or a failed allocation while describing buffers, leave it unchanged.
    last_cause: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) Error!Session {
        const cpu = allocator.create(CpuState) catch return error.OutOfMemory;
        cpu.* = CpuState.init(allocator);
        return .{ .allocator = allocator, .cpu = cpu };
    }

    pub fn deinit(self: *Session) void {
        for (&self.entries) |*entry| {
            if (entry.live) self.releaseEntry(entry);
        }
        self.cpu.deinit();
        self.allocator.destroy(self.cpu);
        self.* = undefined;
    }

    /// A caller passes a program's wire bytes, the versioned byte encoding of a tensor program, to
    /// get a handle it can run. The call decodes the bytes, compiles the program for the CPU, and
    /// loads the result into a free slot. Bad bytes return `error.InvalidProgram` or
    /// `error.UnsupportedVersion`, a compile or load failure returns `error.CompileFailed` or
    /// `error.OutOfMemory`, and a full table returns `error.TooManyPrograms`. The caller may free
    /// `bytes` once the call returns, because decoding copies names and payloads into the program.
    pub fn compile(self: *Session, bytes: []const u8) Error!Handle {
        const index = self.freeIndex() orelse return error.TooManyPrograms;
        var program = tensor.wire.decode(self.allocator, bytes) catch |err| {
            return self.fail(decodeError(err), err);
        };
        errdefer program.deinit();
        const cpu = self.cpu.handle();
        const options = accy.executable.FragmentCompilerOptions{ .artifact_format = .cpu_object };
        const compiled = tensor.lower.compileFragment(
            self.allocator,
            cpu,
            &program,
            options,
        ) catch |err| return self.fail(compileError(err), err);
        const fragment = accy.executable.loadFragment(
            self.allocator,
            cpu,
            compiled,
            options,
        ) catch |err| return self.fail(compileError(err), err);
        errdefer fragment.deinit();
        const capabilities = cpu.queryCapabilities() catch |err| {
            return self.fail(compileError(err), err);
        };
        const min_alignment = capabilities.memory.min_buffer_alignment;
        const artifact_plan = compiled.artifactPlan();
        const descriptors = try describe(self.allocator, &program, artifact_plan, min_alignment);
        std.debug.assert(descriptors.len == program.parameters.len + program.outputs.len);

        const entry = &self.entries[index];
        std.debug.assert(!entry.live);
        entry.* = .{
            .live = true,
            .generation = entry.generation,
            .program = program,
            .compiled = compiled,
            .fragment = fragment,
            .descriptors = descriptors,
            .input_count = program.parameters.len,
        };
        return .{ .index = index, .generation = entry.generation };
    }

    pub fn inputDescriptors(self: *const Session, handle: Handle) Error![]const Descriptor {
        const entry = &self.entries[try self.indexOf(handle)];
        return entry.descriptors[0..entry.input_count];
    }

    pub fn outputDescriptors(self: *const Session, handle: Handle) Error![]const Descriptor {
        const entry = &self.entries[try self.indexOf(handle)];
        return entry.descriptors[entry.input_count..];
    }

    /// A caller runs a compiled program on its own input and output buffers. The input and output
    /// slices follow the program's descriptors in order, and a count that does not match returns
    /// `error.InvalidBuffer`. The run uses the caller's buffers in place wherever the plans allow,
    /// and copies any input the program writes so the caller's inputs stay unchanged. Each output
    /// must share no bytes with any input or with another output, and a buffer that breaks this or
    /// the descriptor's size or alignment returns `error.InvalidBuffer`. `scratch` backs the
    /// short-lived state of one launch, and a launch failure returns `error.LaunchFailed`.
    pub fn invoke(
        self: *Session,
        handle: Handle,
        scratch: std.mem.Allocator,
        input_bytes: []const []const u8,
        output_bytes: []const []u8,
    ) Error!void {
        const entry = &self.entries[try self.indexOf(handle)];
        std.debug.assert(entry.live);
        const output_count = entry.descriptors.len - entry.input_count;
        if (input_bytes.len != entry.input_count) return error.InvalidBuffer;
        if (output_bytes.len != output_count) return error.InvalidBuffer;
        const bindings = binding.prepareBorrowed(
            self.allocator,
            self.cpu.handle(),
            entry.compiled.artifactPlan(),
            entry.compiled.launchPlan(),
            input_bytes,
            output_bytes,
        ) catch |err| return self.fail(bindError(err), err);
        defer bindings.deinit();
        entry.fragment.submitInvocationWithOptions(scratch, bindings, .{}) catch |err| {
            return self.fail(launchError(err), err);
        };
        entry.fragment.completeInvocationWithOptions(.{}) catch |err| {
            return self.fail(launchError(err), err);
        };
        binding.completeBorrowed(bindings, output_bytes) catch |err| {
            return self.fail(launchError(err), err);
        };
    }

    /// Frees the compiled program, its descriptors and its decoded form. After the call the handle
    /// and every descriptor slice from that program are invalid, and the handle is refused with
    /// `error.InvalidHandle`.
    pub fn release(self: *Session, handle: Handle) Error!void {
        const entry = &self.entries[try self.indexOf(handle)];
        self.releaseEntry(entry);
    }

    fn releaseEntry(self: *Session, entry: *Entry) void {
        std.debug.assert(entry.live);
        entry.fragment.deinit();
        self.allocator.free(entry.descriptors);
        entry.program.deinit();
        entry.* = .{ .generation = entry.generation +% 1 };
    }

    fn indexOf(self: *const Session, handle: Handle) Error!u32 {
        if (handle.index >= max_programs) return error.InvalidHandle;
        const entry = &self.entries[handle.index];
        if (!entry.live or entry.generation != handle.generation) return error.InvalidHandle;
        return handle.index;
    }

    fn freeIndex(self: *const Session) ?u32 {
        for (&self.entries, 0..) |*entry, index| {
            if (!entry.live) return @intCast(index);
        }
        return null;
    }

    fn fail(self: *Session, public: Error, cause: anyerror) Error {
        self.last_cause = cause;
        return public;
    }
};

fn describe(
    allocator: std.mem.Allocator,
    program: *const Program,
    artifact_plan: *const BackendArtifactPlan,
    min_alignment: u32,
) Error![]Descriptor {
    const input_count = program.parameters.len;
    if (artifact_plan.input_slot_ids.len != input_count) return error.CompileFailed;
    if (artifact_plan.output_slot_ids.len != program.outputs.len) return error.CompileFailed;
    const count = input_count + program.outputs.len;
    const descriptors = allocator.alloc(Descriptor, count) catch return error.OutOfMemory;
    errdefer allocator.free(descriptors);

    const inputs = descriptors[0..input_count];
    for (program.parameters, artifact_plan.input_slot_ids, inputs) |id, slot_id, *descriptor| {
        const ty = program.values[id.index];
        descriptor.* = try describeSlot(ty, artifact_plan, slot_id, min_alignment);
    }
    const outputs = descriptors[input_count..];
    for (program.outputs, artifact_plan.output_slot_ids, outputs) |id, slot_id, *descriptor| {
        const ty = program.values[id.index];
        descriptor.* = try describeSlot(ty, artifact_plan, slot_id, min_alignment);
    }
    return descriptors;
}

fn describeSlot(
    ty: tensor.Type,
    artifact_plan: *const BackendArtifactPlan,
    slot_id: usize,
    min_alignment: u32,
) Error!Descriptor {
    const slot = artifact_plan.slotById(slot_id) orelse return error.CompileFailed;
    const slot_bytes = slot.byte_size orelse return error.CompileFailed;
    const byte_size = ty.byteCount() catch return error.CompileFailed;
    if (slot_bytes != byte_size) return error.CompileFailed;
    const alignment = @max(slot.alignment, min_alignment, 1);
    return .{
        .dtype = ty.dtype,
        .dims = ty.dims,
        .byte_size = byte_size,
        .alignment = std.math.cast(u32, alignment) orelse return error.CompileFailed,
    };
}

fn decodeError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedVersion => error.UnsupportedVersion,
        else => error.InvalidProgram,
    };
}

fn compileError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompileFailed,
    };
}

fn bindError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBuffer, error.ReadBufferDestinationTooSmall => error.InvalidBuffer,
        error.CapabilityMismatch => error.InvalidBuffer,
        else => error.LaunchFailed,
    };
}

fn launchError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.LaunchFailed,
    };
}
