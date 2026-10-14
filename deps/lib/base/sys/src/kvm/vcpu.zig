const std = @import("std");
const abi = @import("abi.zig");
const run_exit = @import("exit.zig");
const state = @import("state.zig");
const types = @import("types.zig");

pub const RunControls = struct {
    request_interrupt_window: bool = false,
    cr8: u64 = 0,
    apic_base: u64 = 0,
};

pub const RunStatus = struct {
    ready_for_interrupt_injection: bool,
    interrupts_enabled: bool,
    flags: u16,
    cr8: u64,
    apic_base: u64,
};

pub const Vcpu = struct {
    pub const descriptor_capacity: usize = 1;
    pub const mapping_capacity: usize = 1;

    operations: types.Operations,
    descriptor: types.Descriptor,
    mapping: []align(types.page_size) u8,
    extensions: types.Extensions,
    active: bool = true,

    pub fn deinit(self: *@This()) void {
        if (!self.active) return;
        std.debug.assert(self.descriptor >= 0);
        std.debug.assert(self.mapping.len >= abi.minimum_run_bytes);
        self.operations.unmap(self.mapping);
        self.operations.close(self.descriptor);
        self.active = false;
    }

    pub fn run(self: *@This()) (types.RunError || run_exit.DecodeError)!run_exit.Exit {
        if (!self.active) return error.Closed;
        std.debug.assert(self.mapping.len >= abi.minimum_run_bytes);
        switch (self.operations.control(self.descriptor, abi.request.run, 0)) {
            .value => {},
            .failure => |code| return runError(code),
        }
        return run_exit.decode(self.mapping);
    }

    pub fn setImmediateExit(self: *@This(), requested: bool) types.RunError!void {
        if (!self.active) return error.Closed;
        if (self.extensions.immediate_exit == 0) {
            return error.UnsupportedOperation;
        }
        std.debug.assert(self.mapping.len >= @sizeOf(abi.RunHeader));
        const header: *abi.RunHeader = @ptrCast(self.mapping.ptr);
        @atomicStore(u8, &header.immediate_exit, @intFromBool(requested), .monotonic);
    }

    pub fn setRunControls(self: *@This(), controls: RunControls) types.RunError!void {
        if (!self.active) return error.Closed;
        const header = self.runHeader();
        header.request_interrupt_window = @intFromBool(controls.request_interrupt_window);
        header.cr8 = controls.cr8;
        header.apic_base = controls.apic_base;
    }

    pub fn runStatus(self: *@This()) types.RunError!RunStatus {
        if (!self.active) return error.Closed;
        const header = self.runHeader();
        return .{
            .ready_for_interrupt_injection = header.ready_for_interrupt_injection != 0,
            .interrupts_enabled = header.interrupts_enabled != 0,
            .flags = header.flags,
            .cr8 = header.cr8,
            .apic_base = header.apic_base,
        };
    }

    pub fn capture(self: *@This(), parts: state.Parts) types.StateError!state.Fixed {
        if (!self.active) return error.Closed;
        if (!fixedStateSupported(parts, self.extensions)) return error.UnsupportedState;
        var result = std.mem.zeroes(state.Fixed);
        result.valid = parts;
        try self.captureBasic(parts, &result);
        try self.captureExtended(parts, &result);
        return result;
    }

    pub fn restore(self: *@This(), snapshot: *const state.Fixed) types.StateError!void {
        if (!self.active) return error.Closed;
        if (!fixedStateSupported(snapshot.valid, self.extensions)) {
            return error.UnsupportedState;
        }
        try self.restoreBasic(snapshot);
        try self.restoreExtended(snapshot);
    }

    pub fn readMsrs(self: *@This(), buffer: anytype) types.StateError!void {
        if (!self.active) return error.Closed;
        validateMsrBuffer(@TypeOf(buffer.*));
        if (buffer.count > buffer.entries.len) return error.CapacityExceeded;
        const result = types.controlRetry(
            self.operations,
            self.descriptor,
            abi.request.get_msrs,
            @intFromPtr(buffer),
        );
        try expectTransfer(result, buffer.count);
    }

    pub fn writeMsrs(self: *@This(), buffer: anytype) types.StateError!void {
        if (!self.active) return error.Closed;
        validateMsrBuffer(@TypeOf(buffer.*));
        if (buffer.count > buffer.entries.len) return error.CapacityExceeded;
        const result = types.controlRetry(
            self.operations,
            self.descriptor,
            abi.request.set_msrs,
            @intFromPtr(buffer),
        );
        try expectTransfer(result, buffer.count);
    }

    pub fn readCpuid(self: *@This(), buffer: anytype) types.StateError!void {
        if (!self.active) return error.Closed;
        if (self.extensions.extended_cpuid == 0) return error.UnsupportedState;
        validateCpuidBuffer(@TypeOf(buffer.*));
        if (buffer.count > buffer.entries.len) return error.CapacityExceeded;
        try types.stateControl(
            self.operations,
            self.descriptor,
            abi.request.get_cpuid,
            @intFromPtr(buffer),
        );
    }

    pub fn writeCpuid(self: *@This(), buffer: anytype) types.StateError!void {
        if (!self.active) return error.Closed;
        if (self.extensions.extended_cpuid == 0) return error.UnsupportedState;
        validateCpuidBuffer(@TypeOf(buffer.*));
        if (buffer.count > buffer.entries.len) return error.CapacityExceeded;
        try types.stateControl(
            self.operations,
            self.descriptor,
            abi.request.set_cpuid,
            @intFromPtr(buffer),
        );
    }

    fn captureBasic(
        self: *@This(),
        parts: state.Parts,
        result: *state.Fixed,
    ) types.StateError!void {
        if (parts.registers) try self.get(abi.request.get_registers, &result.registers);
        if (parts.special_registers) {
            try self.get(abi.request.get_special_registers, &result.special_registers);
        }
        if (parts.fpu) try self.get(abi.request.get_fpu, &result.fpu);
    }

    fn captureExtended(
        self: *@This(),
        parts: state.Parts,
        result: *state.Fixed,
    ) types.StateError!void {
        if (parts.events) try self.get(abi.request.get_vcpu_events, &result.events);
        if (parts.debug_registers) {
            try self.get(abi.request.get_debug_registers, &result.debug_registers);
        }
        if (parts.xsave) try self.get(abi.request.get_xsave, &result.xsave);
        if (parts.xcrs) try self.get(abi.request.get_xcrs, &result.xcrs);
        if (parts.multiprocessor) {
            try self.get(abi.request.get_mp_state, &result.multiprocessor);
        }
    }

    fn restoreBasic(self: *@This(), snapshot: *const state.Fixed) types.StateError!void {
        if (snapshot.valid.special_registers) {
            try self.set(abi.request.set_special_registers, &snapshot.special_registers);
        }
        if (snapshot.valid.registers) {
            try self.set(abi.request.set_registers, &snapshot.registers);
        }
        if (snapshot.valid.fpu) try self.set(abi.request.set_fpu, &snapshot.fpu);
    }

    fn restoreExtended(
        self: *@This(),
        snapshot: *const state.Fixed,
    ) types.StateError!void {
        if (snapshot.valid.events) {
            try self.set(abi.request.set_vcpu_events, &snapshot.events);
        }
        if (snapshot.valid.debug_registers) {
            try self.set(abi.request.set_debug_registers, &snapshot.debug_registers);
        }
        if (snapshot.valid.xsave) try self.set(abi.request.set_xsave, &snapshot.xsave);
        if (snapshot.valid.xcrs) try self.set(abi.request.set_xcrs, &snapshot.xcrs);
        if (snapshot.valid.multiprocessor) {
            try self.set(abi.request.set_mp_state, &snapshot.multiprocessor);
        }
    }

    fn get(self: *@This(), request: u32, destination: anytype) types.StateError!void {
        std.debug.assert(request != 0);
        try types.stateControl(
            self.operations,
            self.descriptor,
            request,
            @intFromPtr(destination),
        );
    }

    fn set(self: *@This(), request: u32, source: anytype) types.StateError!void {
        std.debug.assert(request != 0);
        try types.stateControl(
            self.operations,
            self.descriptor,
            request,
            @intFromPtr(source),
        );
    }

    fn runHeader(self: *@This()) *abi.RunHeader {
        std.debug.assert(self.mapping.len >= @sizeOf(abi.RunHeader));
        return @ptrCast(self.mapping.ptr);
    }
};

fn runError(code: types.Errno) types.RunError {
    return switch (code) {
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .ACCES, .PERM => error.AccessDenied,
        .BADF, .NODEV => error.Closed,
        .FAULT, .INVAL => error.InvalidRunState,
        .NOSYS, .NOTTY, .OPNOTSUPP => error.UnsupportedOperation,
        else => error.RunFailed,
    };
}

fn expectTransfer(result: types.RawResult, expected: u32) types.StateError!void {
    switch (result) {
        .value => |value| {
            if (value != expected) return error.PartialTransfer;
        },
        .failure => |code| return switch (code) {
            .ACCES, .PERM => error.AccessDenied,
            .BADF, .NODEV => error.Closed,
            .INVAL, .NOSYS, .NOTTY, .OPNOTSUPP => error.UnsupportedState,
            else => error.StateFailed,
        },
    }
}

fn fixedStateSupported(parts: state.Parts, extensions: types.Extensions) bool {
    if (parts.events and extensions.vcpu_events == 0) return false;
    if (parts.debug_registers and extensions.debug_registers == 0) return false;
    if (parts.xsave and extensions.xsave == 0) return false;
    if (parts.xcrs and extensions.xcrs == 0) return false;
    if (parts.multiprocessor and extensions.multiprocessor_state == 0) return false;
    return true;
}

fn validateMsrBuffer(comptime Buffer: type) void {
    comptime {
        if (!@hasField(Buffer, "count") or !@hasField(Buffer, "entries")) {
            @compileError("expected abi.MsrBuffer");
        }
        if (@FieldType(Buffer, "count") != u32) @compileError("invalid MSR count type");
        if (@typeInfo(@FieldType(Buffer, "entries")).array.child != abi.MsrEntry) {
            @compileError("invalid MSR entry type");
        }
        if (@offsetOf(Buffer, "entries") != @sizeOf(abi.MsrHeader)) {
            @compileError("invalid MSR buffer layout");
        }
    }
}

fn validateCpuidBuffer(comptime Buffer: type) void {
    comptime {
        if (!@hasField(Buffer, "count") or !@hasField(Buffer, "entries")) {
            @compileError("expected abi.CpuidBuffer");
        }
        if (@FieldType(Buffer, "count") != u32) @compileError("invalid CPUID count type");
        if (@typeInfo(@FieldType(Buffer, "entries")).array.child != abi.CpuidEntry) {
            @compileError("invalid CPUID entry type");
        }
        if (@offsetOf(Buffer, "entries") != @sizeOf(abi.CpuidHeader)) {
            @compileError("invalid CPUID buffer layout");
        }
    }
}
