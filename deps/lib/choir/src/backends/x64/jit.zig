const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const capacity = @import("capacity.zig");
const emit = @import("emit.zig");
const failures = @import("failures.zig");
const abi = @import("abi.zig");
const invoke = @import("invoke.zig");
const dialects = @import("../../dialects/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const debug_info = backends.debug_info;
const machine = backends.machine_code;
const sys = @import("sys");
const diagnostics = @import("../../root.zig").diagnostics;

const Mapping = []align(std.heap.page_size_min) u8;

comptime {
    std.debug.assert(machine.max_data_alignment <= std.heap.page_size_min);
}

/// The bytes the kernel reserves for a mapping of `byte_count`. `sys.memory.mapAnonymous` rounds
/// a nonzero request up to a page, and zero reserves nothing because `link` skips the call rather
/// than mapping a page for no data. A request too large to page-align saturates to the whole
/// address space. A budget short of that refuses the saturated charge in `admitMapping`, and a
/// budget equal to it admits the charge and lets the mapping call fail.
fn mappedSize(byte_count: usize) u64 {
    if (byte_count == 0) return 0;
    const aligned = sys.memory.pageAlign(byte_count) orelse return std.math.maxInt(u64);
    return aligned;
}

/// Names one module compiled or loaded into a `JitRuntime`.
/// Releasing the module retires its generation, so the handle stops resolving.
pub const ModuleHandle = struct {
    index: u32,
    generation: u32,
};

pub const HandleError = error{InvalidModuleHandle};
pub const LookupError = HandleError || error{FunctionNotFound};
pub const CallError = LookupError || invoke.Error;

pub const LoadError = error{ InvalidArtifact, SymbolNotFound, JitRuntimeFull };
pub const MachineCodeArtifactError = std.mem.Allocator.Error ||
    sys.memory.MapError ||
    sys.memory.ProtectError ||
    LoadError;

const FunctionEntry = struct {
    offset: usize,
    size: usize,
    signature: artifact.Signature,
    line_table: ?debug_info.LineTable = null,
    debug_object: ?debug_info.JitDebugHandle = null,

    fn deinit(self: *FunctionEntry, allocator: std.mem.Allocator) void {
        if (self.debug_object) |*handle| handle.deinit(allocator);
        if (self.line_table) |*table| table.deinit();
        self.* = undefined;
    }
};

const FoundFunction = struct {
    address: usize,
    entry: *const FunctionEntry,
};

const Module = struct {
    generation: u32,
    live: bool,
    code: ?Mapping,
    /// Read-only bytes that the code addresses through absolute relocations.
    data: ?Mapping,
    functions: std.StringHashMapUnmanaged(FunctionEntry),

    const staged: Module = .{
        .generation = 0,
        .live = true,
        .code = null,
        .data = null,
        .functions = .empty,
    };

    fn functionAddress(self: *const Module, entry: *const FunctionEntry) usize {
        const code = self.code.?;
        std.debug.assert(entry.offset + entry.size <= code.len);
        return @intFromPtr(code.ptr) + entry.offset;
    }

    /// The bytes this module holds mapped, code and read-only data together. `unload` unmaps
    /// exactly those bytes, so `release` credits back the figure `install` charged.
    fn mappedBytes(self: *const Module) u64 {
        var total: u64 = 0;
        if (self.code) |mapping| total += mapping.len;
        if (self.data) |mapping| total += mapping.len;
        return total;
    }

    /// Unregisters debug objects before unmapping the code they describe, then unmaps the data.
    /// Keeps the generation.
    fn unload(self: *Module, allocator: std.mem.Allocator) void {
        std.debug.assert(self.live);
        var iterator = self.functions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit(allocator);
        if (self.code) |mapping| sys.memory.unmap(mapping);
        if (self.data) |mapping| sys.memory.unmap(mapping);
        self.* = .{
            .generation = self.generation,
            .live = false,
            .code = null,
            .data = null,
            .functions = .empty,
        };
    }
};

/// One module's code and data symbols, with every relocation still unpatched.
const Image = struct {
    code: []const u8,
    calls: []const emit.CallRelocation,
    data: *const machine.DataSymbolSet,
    data_relocations: []const machine.DataRelocation,
};

/// Concatenates emitted functions into one image.
const ImageBuilder = struct {
    code: std.ArrayListUnmanaged(u8) = .empty,
    calls: std.ArrayListUnmanaged(emit.CallRelocation) = .empty,
    data: machine.DataSymbolSet = .{},
    data_relocations: std.ArrayListUnmanaged(machine.DataRelocation) = .empty,

    fn deinit(self: *ImageBuilder, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.calls.deinit(allocator);
        self.data.deinit(allocator);
        self.data_relocations.deinit(allocator);
        self.* = undefined;
    }

    /// Appends the emitter's current function, rebases its relocations, and merges its data
    /// symbols. Returns the function's offset in the image.
    fn append(
        self: *ImageBuilder,
        allocator: std.mem.Allocator,
        emitter: *const emit.Emitter,
    ) (std.mem.Allocator.Error || machine.DataSymbolError)!usize {
        const code = emitter.getCode();
        std.debug.assert(code.len != 0);
        const offset = self.code.items.len;
        try self.code.appendSlice(allocator, code);
        for (emitter.call_relocations.items) |relocation| {
            try self.calls.append(allocator, .{
                .offset = offset + relocation.offset,
                .target = relocation.target,
            });
        }
        for (emitter.data_symbols.items()) |symbol| try self.data.put(allocator, symbol);
        for (emitter.data_relocations.items) |relocation| {
            var rebased = relocation;
            rebased.offset += offset;
            try self.data_relocations.append(allocator, rebased);
        }
        std.debug.assert(self.code.items.len == offset + code.len);
        return offset;
    }

    fn image(self: *const ImageBuilder) Image {
        return .{
            .code = self.code.items,
            .calls = self.calls.items,
            .data = &self.data,
            .data_relocations = self.data_relocations.items,
        };
    }
};

/// Executable modules addressed by generation-checked handles.
/// Each module owns its code and data until `release`. Compiling or loading another module never
/// moves or frees them.
pub const JitRuntime = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    live_modules: u32,
    /// The bytes live modules hold mapped, as the kernel reserved them. The running total moves
    /// alongside `live_modules`, at `install` and `release`. A compile that fails partway spends
    /// none of the budget, because the module never reaches `install` and its `errdefer` unmaps
    /// whatever it had mapped.
    mapped_bytes: u64,
    modules: std.ArrayListUnmanaged(Module),
    external_symbols: std.StringHashMapUnmanaged(usize),
    emitter: emit.Emitter,

    pub const Limits: type = capacity.Limits;

    pub fn init(allocator: std.mem.Allocator, limits: Limits) JitRuntime {
        std.debug.assert(limits.live_modules != 0);
        std.debug.assert(limits.mapped_bytes != 0);
        return .{
            .allocator = allocator,
            .limits = limits,
            .live_modules = 0,
            .mapped_bytes = 0,
            .modules = .empty,
            .external_symbols = .empty,
            .emitter = emit.Emitter.init(allocator),
        };
    }

    pub fn deinit(self: *JitRuntime) void {
        for (self.modules.items) |*module| {
            if (module.live) module.unload(self.allocator);
        }
        self.modules.deinit(self.allocator);

        var names = self.external_symbols.keyIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.external_symbols.deinit(self.allocator);

        self.emitter.deinit();
        self.* = undefined;
    }

    /// Compiles every function definition in `module` into a new module. Calls resolve against the
    /// module's own functions first, then registered external symbols. Data symbols resolve against
    /// the module's own read-only data. Fails with `error.ConflictingDataSymbol` when two constants
    /// give one data symbol name different bytes or alignment.
    /// Reports one error diagnostic when a function fails to compile, located at the innermost
    /// operation whose emission failed, or otherwise at the function.
    /// Fails with `error.SymbolNotFound` when neither the module nor a registered external symbol
    /// defines a call's target, and reports one error diagnostic at the first `func.call` naming
    /// the target, or at the calling function when no `func.call` names it.
    /// Fails with `error.OutOfMemory` when an allocation fails, and reports nothing.
    /// Fails with `error.JitRuntimeFull`, and reports nothing, when the runtime already holds
    /// `limits.live_modules` modules or when this module's pages would carry it past
    /// `limits.mapped_bytes`. A `release` admits the next module under either bound.
    /// A failed compile leaves every existing module untouched and spends none of either budget.
    pub fn compile(self: *JitRuntime, module: *ir.Operation) !ModuleHandle {
        const region = module.getRegion(0) orelse return error.NoModuleBody;
        const block = region.getEntryBlock() orelse return error.NoEntryBlock;
        const index = try self.reserveModule();

        var staged: Module = .staged;
        errdefer staged.unload(self.allocator);
        var builder: ImageBuilder = .{};
        defer builder.deinit(self.allocator);

        var op_iter = block.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            op_iter = op.next_op;
            if (!std.mem.eql(u8, op.name.name, dialects.FuncDialect.FuncOp.operation_name)) continue;
            if (op.getRegion(0) == null) continue;
            try self.emitFunction(&staged, &builder, op);
        }
        if (builder.code.items.len != 0) {
            try self.resolveCalls(module, &staged, builder.calls.items);
            try self.link(&staged, builder.image());
        }
        return self.install(index, staged);
    }

    /// Emits one function into the module image. Relocations stay unpatched until `link`.
    fn emitFunction(
        self: *JitRuntime,
        staged: *Module,
        builder: *ImageBuilder,
        func: *ir.Operation,
    ) !void {
        defer self.emitter.discardFunctionState();
        self.stageFunction(staged, builder, func) catch |err| {
            failures.Failure.report(.{
                .stage = .emit,
                .operation = self.emitter.failed_operation orelse func,
                .err = err,
            });
            return err;
        };
    }

    fn stageFunction(
        self: *JitRuntime,
        staged: *Module,
        builder: *ImageBuilder,
        func: *ir.Operation,
    ) !void {
        const name = ir.SymbolTable.getSymbolName(func) orelse return error.NoFunctionName;
        if (staged.functions.contains(name)) return error.DuplicateSymbol;
        const signature = try signatureOf(func);

        try self.emitter.emitFunction(func);
        const size = self.emitter.getCode().len;
        if (size == 0) return error.EmptyFunction;
        const offset = try builder.append(self.allocator, &self.emitter);

        try staged.functions.ensureUnusedCapacity(self.allocator, 1);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        var entry = FunctionEntry{ .offset = offset, .size = size, .signature = signature };
        errdefer entry.deinit(self.allocator);
        entry.line_table = try self.emitter.takeLineTable();
        staged.functions.putAssumeCapacityNoClobber(owned_name, entry);
    }

    fn resolveCalls(
        self: *const JitRuntime,
        module: *ir.Operation,
        staged: *const Module,
        calls: []const emit.CallRelocation,
    ) error{SymbolNotFound}!void {
        for (calls) |call_site| {
            if (staged.functions.contains(call_site.target)) continue;
            if (self.externalAddress(call_site.target) != null) continue;
            failures.Failure.report(.{
                .stage = .link,
                .operation = callerOf(module, staged, call_site),
                .err = error.SymbolNotFound,
                .symbol = call_site.target,
            });
            return error.SymbolNotFound;
        }
    }

    /// Maps the image's data writable, copies it, seals it as its symbols require, then maps
    /// the code writable, patches every call and data address, and seals the code executable.
    ///
    /// A module's data is one mapping, so one writable global leaves the whole mapping
    /// writable, read only symbols included. An object file places each section on its own and
    /// carries no such weakening.
    fn link(self: *JitRuntime, staged: *Module, image: Image) !void {
        std.debug.assert(staged.code == null);
        std.debug.assert(staged.data == null);
        std.debug.assert(image.code.len != 0);
        const symbols = image.data.items();
        var layout = machine.DataLayout.init(self.allocator, symbols) catch |err| switch (err) {
            error.InvalidDataSymbol => unreachable,
            else => |narrow| return narrow,
        };
        defer layout.deinit(self.allocator);
        try self.admitMapping(mappedSize(image.code.len) +| mappedSize(layout.size));

        const writable: sys.memory.Protection = .{ .read = true, .write = true };
        if (layout.size != 0) {
            const data = try sys.memory.mapAnonymous(layout.size, writable);
            std.debug.assert(data.len == mappedSize(layout.size));
            staged.data = data;
            layout.write(symbols, data);
            if (!anyWritable(symbols)) try sys.memory.protect(data, .{ .read = true });
        }

        const mapping = try sys.memory.mapAnonymous(image.code.len, writable);
        std.debug.assert(mapping.len == mappedSize(image.code.len));
        staged.code = mapping;
        const code = mapping[0..image.code.len];
        @memcpy(code, image.code);
        for (image.calls) |call_site| {
            const target = if (staged.functions.getPtr(call_site.target)) |callee|
                staged.functionAddress(callee)
            else
                self.externalAddress(call_site.target) orelse return error.SymbolNotFound;
            writeAddress(code, call_site.offset, target);
        }
        for (image.data_relocations) |relocation| {
            std.debug.assert(relocation.width_bits == 64);
            const symbol = image.data.indexOf(relocation.target).?;
            const base: u64 = @intFromPtr(staged.data.?.ptr) + layout.offsets[symbol];
            const addend: u64 = @bitCast(relocation.addend);
            writeAddress(code, relocation.offset, base +% addend);
        }
        try sys.memory.protect(mapping, .{ .read = true, .execute = true });
    }

    /// Reports whether any symbol asks for storage the code may write.
    fn anyWritable(symbols: []const machine.DataSymbol) bool {
        for (symbols) |symbol| {
            if (symbol.section != .rodata) return true;
        }
        return false;
    }

    /// Reserves a slot so that installing a finished module cannot fail.
    fn reserveModule(self: *JitRuntime) error{ OutOfMemory, JitRuntimeFull }!u32 {
        std.debug.assert(self.live_modules <= self.limits.live_modules);
        if (self.live_modules >= self.limits.live_modules) return error.JitRuntimeFull;
        for (self.modules.items, 0..) |*module, index| {
            if (module.live) continue;
            if (module.generation == std.math.maxInt(u32)) continue;
            return @intCast(index);
        }
        const index = std.math.cast(u32, self.modules.items.len) orelse return error.JitRuntimeFull;
        try self.modules.ensureUnusedCapacity(self.allocator, 1);
        return index;
    }

    /// Refuses `charge` bytes before the runtime maps code or data. `reserveModule` checks the
    /// slot count at the top of a compile, but a module's size is not known until its code is
    /// emitted, so `link` checks the byte budget instead. Both checks answer the same capacity
    /// question and fail with `error.JitRuntimeFull`.
    ///
    /// The sum saturates rather than the budget being subtracted from, so a runtime already over
    /// its budget refuses instead of wrapping. A host reaches that state by lowering
    /// `limits.mapped_bytes` under what is already live, and the slot count answers the same
    /// move the same way.
    fn admitMapping(self: *const JitRuntime, charge: u64) error{JitRuntimeFull}!void {
        if (self.mapped_bytes +| charge > self.limits.mapped_bytes) return error.JitRuntimeFull;
    }

    fn install(self: *JitRuntime, index: u32, staged: Module) ModuleHandle {
        std.debug.assert(staged.live);
        std.debug.assert(self.live_modules < self.limits.live_modules);
        self.live_modules += 1;
        const charge = staged.mappedBytes();
        std.debug.assert(self.mapped_bytes +| charge <= self.limits.mapped_bytes);
        self.mapped_bytes += charge;
        var module = staged;
        if (index == self.modules.items.len) {
            module.generation = 1;
            self.modules.appendAssumeCapacity(module);
        } else {
            const slot = &self.modules.items[index];
            std.debug.assert(!slot.live);
            module.generation = slot.generation + 1;
            slot.* = module;
        }
        return .{ .index = index, .generation = module.generation };
    }

    /// Unmaps the module's code and data. Function pointers and data addresses taken from it dangle
    /// afterward.
    pub fn release(self: *JitRuntime, handle: ModuleHandle) HandleError!void {
        const module = try self.liveModule(handle);
        const credit = module.mappedBytes();
        module.unload(self.allocator);
        std.debug.assert(self.live_modules != 0);
        self.live_modules -= 1;
        std.debug.assert(self.mapped_bytes >= credit);
        self.mapped_bytes -= credit;
    }

    fn liveModule(self: *const JitRuntime, handle: ModuleHandle) HandleError!*Module {
        if (handle.index >= self.modules.items.len) return error.InvalidModuleHandle;
        const module = &self.modules.items[handle.index];
        if (!module.live) return error.InvalidModuleHandle;
        if (module.generation != handle.generation) return error.InvalidModuleHandle;
        return module;
    }

    fn findFunction(
        self: *const JitRuntime,
        handle: ModuleHandle,
        name: []const u8,
    ) LookupError!FoundFunction {
        const module = try self.liveModule(handle);
        const entry = module.functions.getPtr(name) orelse return error.FunctionNotFound;
        return .{ .address = module.functionAddress(entry), .entry = entry };
    }

    /// Returns the address of `name` without checking how a caller will call it.
    /// Fails with `error.InvalidModuleHandle` when `handle` no longer resolves, and with
    /// `error.FunctionNotFound` when its module has no function `name`.
    pub fn functionAddress(
        self: *const JitRuntime,
        handle: ModuleHandle,
        name: []const u8,
    ) LookupError!usize {
        const found = try self.findFunction(handle, name);
        return found.address;
    }

    /// Returns the parameter and result types recorded for `name`.
    /// Fails with `error.InvalidModuleHandle` when `handle` no longer resolves, and with
    /// `error.FunctionNotFound` when its module has no function `name`.
    pub fn functionSignature(
        self: *const JitRuntime,
        handle: ModuleHandle,
        name: []const u8,
    ) LookupError!artifact.Signature {
        const found = try self.findFunction(handle, name);
        return found.entry.signature;
    }

    /// Returns `name` as `FunctionPointer` when the signature derived from that type equals the
    /// recorded one. `backends.signature.ofZigFunction` gives the type mapping.
    /// Fails with `error.InvalidModuleHandle` or `error.FunctionNotFound` when the lookup fails,
    /// and with `error.SignatureMismatch` when the signatures differ.
    pub fn getFunction(
        self: *const JitRuntime,
        handle: ModuleHandle,
        name: []const u8,
        comptime FunctionPointer: type,
    ) CallError!FunctionPointer {
        const expected = backends.signature.ofZigFunction(FunctionPointer);
        const found = try self.findFunction(handle, name);
        if (!found.entry.signature.eql(&expected)) return error.SignatureMismatch;
        return @ptrFromInt(found.address);
    }

    /// Calls `name` with `args` and stores its results in `results`.
    /// Fails with `error.InvalidModuleHandle` or `error.FunctionNotFound` when the lookup fails.
    /// Fails with `error.SignatureMismatch`, without calling, when an argument's type, the argument
    /// count, or the number of result slots differs from the recorded signature.
    pub fn call(
        self: *const JitRuntime,
        handle: ModuleHandle,
        name: []const u8,
        args: []const invoke.Value,
        results: []invoke.Value,
    ) CallError!void {
        const found = try self.findFunction(handle, name);
        try invoke.call(found.address, &found.entry.signature, args, results);
    }

    /// Binds `name` for modules compiled or loaded afterward. Linked modules keep their targets.
    /// Replacing a name keeps its entry and owned name. A new name past `limits.external_symbols`
    /// fails with `error.JitRuntimeFull` before allocating. Either refusal or allocation failure
    /// leaves the table, its retained storage, and all existing bindings unchanged.
    pub fn registerExternalSymbol(
        self: *JitRuntime,
        name: []const u8,
        addr: usize,
    ) error{ OutOfMemory, JitRuntimeFull }!void {
        if (self.external_symbols.getPtr(name)) |existing| {
            existing.* = addr;
            return;
        }

        const count = self.external_symbols.count();
        if (count >= self.limits.external_symbols) return error.JitRuntimeFull;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.external_symbols.putNoClobber(self.allocator, owned_name, addr);
        std.debug.assert(self.external_symbols.count() == count + 1);
        std.debug.assert(self.external_symbols.count() <= self.limits.external_symbols);
    }

    fn externalAddress(self: *const JitRuntime, name: []const u8) ?usize {
        const address = self.external_symbols.get(name) orelse return null;
        if (address == 0) return null;
        return address;
    }

    /// Loads one machine-code function and its data buffers into a new module.
    /// Call relocations resolve against the function itself, then registered external symbols.
    /// Absolute relocations resolve against the artifact's data buffers.
    /// Fails with `error.InvalidArtifact` before mapping anything when the artifact is malformed or
    /// its function symbol lacks a signature this backend passes and returns.
    /// Fails with `error.JitRuntimeFull` when the runtime already holds `limits.live_modules`
    /// modules or when this artifact's pages would carry it past `limits.mapped_bytes`.
    /// A `release` admits the next module under either bound.
    pub fn loadMachineCodeArtifact(
        self: *JitRuntime,
        serialized: *const artifact.Artifact,
    ) MachineCodeArtifactError!ModuleHandle {
        var view = try ArtifactView.init(self.allocator, serialized);
        defer view.deinit(self.allocator);
        const index = try self.reserveModule();

        var staged: Module = .staged;
        errdefer staged.unload(self.allocator);
        try staged.functions.ensureUnusedCapacity(self.allocator, 1);
        const owned_name = try self.allocator.dupe(u8, view.export_name);
        staged.functions.putAssumeCapacityNoClobber(owned_name, .{
            .offset = 0,
            .size = view.code.len,
            .signature = view.signature,
        });
        self.link(&staged, view.image()) catch |err| switch (err) {
            error.DataTooLarge => return error.InvalidArtifact,
            else => |narrow| return narrow,
        };
        return self.install(index, staged);
    }

    /// Writes every live function's address range and line table.
    /// Registers debug objects with the debugger first where the platform supports it.
    pub fn writeDebugMap(self: *JitRuntime, writer: anytype) !bool {
        if (!self.hasFunctions()) return false;
        self.ensureDebugInfo(writer);

        try writer.writeAll("JIT debug map\n");
        for (self.modules.items) |*module| {
            if (!module.live) continue;
            var iterator = module.functions.iterator();
            while (iterator.next()) |entry| {
                const name = entry.key_ptr.*;
                const function = entry.value_ptr;
                const start = module.functionAddress(function);
                try writer.print("fn {s} 0x{x}..0x{x}\n", .{ name, start, start + function.size });

                const table = function.line_table orelse {
                    try writer.writeAll("  (no line info)\n");
                    continue;
                };
                if (table.isEmpty()) {
                    try writer.writeAll("  (no line info)\n");
                    continue;
                }
                for (table.entries) |line| {
                    const info = line.info;
                    const file = info.file orelse "<unknown>";
                    const name_label = info.name orelse "_";
                    const addr = start + line.offset;
                    try writer.print(
                        "  +0x{x:0>4} 0x{x} {s}:{d}:{d} name={s} op={s}\n",
                        .{ line.offset, addr, file, info.line, info.column, name_label, info.op_name },
                    );
                }
            }
        }
        return true;
    }

    fn hasFunctions(self: *const JitRuntime) bool {
        for (self.modules.items) |*module| {
            if (!module.live) continue;
            if (module.functions.count() != 0) return true;
        }
        return false;
    }

    fn ensureDebugInfo(self: *JitRuntime, writer: anytype) void {
        const arch = sys.capabilities.current.arch;
        const support = debug_info.jitDebugSupport(arch);
        if (!support.supported) {
            if (support.reason) |reason| {
                writer.print("note: {s}; emitting debug map without debugger registration\n", .{reason}) catch {};
            }
            return;
        }
        if (support.note) |note| {
            writer.print("note: {s}\n", .{note}) catch {};
        }

        for (self.modules.items) |*module| {
            if (!module.live) continue;
            var iterator = module.functions.iterator();
            while (iterator.next()) |entry| {
                const function = entry.value_ptr;
                if (function.debug_object != null) continue;
                const table = if (function.line_table) |*line_table| line_table else continue;
                const code = module.code.?[function.offset..][0..function.size];
                function.debug_object = debug_info.registerJitDebugInfo(
                    self.allocator,
                    arch,
                    @intFromPtr(code.ptr),
                    code,
                    table,
                    entry.key_ptr.*,
                ) catch |err| {
                    writer.print("note: JIT debug registration failed: {s}\n", .{@errorName(err)}) catch {};
                    return;
                };
            }
        }
    }
};

fn callerOf(
    module: *ir.Operation,
    staged: *const Module,
    call_site: emit.CallRelocation,
) *ir.Operation {
    var finder = CallFinder{ .callee = call_site.target };
    _ = module.walk(.{ .order = .pre_order }, &finder, CallFinder.visit) catch unreachable;
    if (finder.call) |call| return call;
    var functions = staged.functions.iterator();
    while (functions.next()) |entry| {
        const function = entry.value_ptr;
        if (call_site.offset < function.offset) continue;
        if (call_site.offset - function.offset >= function.size) continue;
        return ir.inspection.functionDefinitionByName(module, entry.key_ptr.*).?;
    }
    unreachable;
}

const CallFinder = struct {
    callee: []const u8,
    call: ?*ir.Operation = null,

    fn visit(self: *CallFinder, op: *ir.Operation) ir.WalkResult {
        std.debug.assert(self.call == null);
        if (!std.mem.eql(u8, op.name.name, dialects.FuncDialect.CallOp.operation_name)) {
            return .advance;
        }
        const callee = dialects.FuncDialect.CallOp.getCallee(.{ .op = op }) orelse return .advance;
        if (!std.mem.eql(u8, callee, self.callee)) return .advance;
        self.call = op;
        return .interrupt;
    }
};

/// Writes a little-endian `address` into the 8-byte window in `code` at `offset`.
fn writeAddress(code: []u8, offset: usize, address: u64) void {
    std.debug.assert(offset <= code.len);
    std.debug.assert(code.len - offset >= 8);
    std.mem.writeInt(u64, code[offset..][0..8], address, .little);
}

fn signatureOf(func: *ir.Operation) backends.signature.Error!artifact.Signature {
    const signature = try backends.signature.ofFunction(func);
    if (!abi.admitsSignature(&signature)) return error.UnsupportedType;
    return signature;
}

const ArtifactView = struct {
    export_name: []const u8,
    code: []const u8,
    signature: artifact.Signature,
    data: machine.DataSymbolSet = .{},
    calls: std.ArrayListUnmanaged(emit.CallRelocation) = .empty,
    data_relocations: std.ArrayListUnmanaged(machine.DataRelocation) = .empty,

    const Error = std.mem.Allocator.Error || error{InvalidArtifact};

    fn init(allocator: std.mem.Allocator, serialized: *const artifact.Artifact) Error!ArtifactView {
        try checkMetadata(serialized.metadata);
        const buffers = serialized.payload.buffers.items;
        const provided = serialized.linkage.provided_symbols.items;
        if (buffers.len == 0 or provided.len != buffers.len) return error.InvalidArtifact;
        const code = buffers[0];
        if (code.format != .machine_code or code.bytes.len == 0) return error.InvalidArtifact;
        const export_symbol = provided[0];
        if (export_symbol.kind != .function) return error.InvalidArtifact;
        if (export_symbol.binding != .external) return error.InvalidArtifact;
        if (export_symbol.name.len == 0) return error.InvalidArtifact;
        if (!std.mem.eql(u8, export_symbol.name, code.name)) return error.InvalidArtifact;
        const signature = export_symbol.signature orelse return error.InvalidArtifact;
        if (!abi.admitsSignature(&signature)) return error.InvalidArtifact;

        var view = ArtifactView{
            .export_name = export_symbol.name,
            .code = code.bytes,
            .signature = signature,
        };
        errdefer view.deinit(allocator);
        for (1..buffers.len) |index| try view.addData(allocator, serialized, index);

        const relocations = serialized.linkage.relocations.items;
        const offsets = try allocator.alloc(usize, relocations.len);
        defer allocator.free(offsets);
        for (relocations, offsets) |relocation, *offset| {
            offset.* = try view.addRelocation(allocator, relocation);
        }
        std.mem.sortUnstable(usize, offsets, {}, std.sort.asc(usize));
        if (offsets.len > 1) {
            for (offsets[0 .. offsets.len - 1], offsets[1..]) |previous, next| {
                if (next - previous < 8) return error.InvalidArtifact;
            }
        }
        std.debug.assert(view.data.items().len + 1 == buffers.len);
        std.debug.assert(view.calls.items.len + view.data_relocations.items.len == relocations.len);
        return view;
    }

    fn deinit(self: *ArtifactView, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.calls.deinit(allocator);
        self.data_relocations.deinit(allocator);
        self.* = undefined;
    }

    fn image(self: *const ArtifactView) Image {
        return .{
            .code = self.code,
            .calls = self.calls.items,
            .data = &self.data,
            .data_relocations = self.data_relocations.items,
        };
    }

    fn checkMetadata(metadata: artifact.Metadata) error{InvalidArtifact}!void {
        if (metadata.kind != .machine_code) return error.InvalidArtifact;
        if (metadata.target.architecture != .x86_64) return error.InvalidArtifact;
        if (metadata.abi.pointer_width_bits != 64) return error.InvalidArtifact;
        if (metadata.abi.endianness != .little) return error.InvalidArtifact;
        const abi_name = metadata.abi.name orelse return error.InvalidArtifact;
        if (!std.mem.eql(u8, abi_name, "sysv")) return error.InvalidArtifact;
        const convention = metadata.abi.calling_convention orelse return error.InvalidArtifact;
        if (!std.mem.eql(u8, convention, "c")) return error.InvalidArtifact;
    }

    /// Adds the raw buffer at `index` as a data symbol under the name its provided symbol gives.
    fn addData(
        self: *ArtifactView,
        allocator: std.mem.Allocator,
        serialized: *const artifact.Artifact,
        index: usize,
    ) Error!void {
        std.debug.assert(index != 0);
        std.debug.assert(index < serialized.linkage.provided_symbols.items.len);
        const buffer = serialized.payload.buffers.items[index];
        const symbol = serialized.linkage.provided_symbols.items[index];
        if (buffer.format != .raw or symbol.kind != .data) return error.InvalidArtifact;
        if (!std.mem.eql(u8, buffer.name, symbol.name)) return error.InvalidArtifact;
        if (std.mem.eql(u8, buffer.name, self.export_name)) return error.InvalidArtifact;
        const binding: machine.DataSymbolBinding = switch (symbol.binding) {
            .local => .local,
            .external => .global,
            .weak => return error.InvalidArtifact,
        };
        const count = self.data.items().len;
        self.data.put(allocator, .{
            .name = buffer.name,
            .bytes = buffer.bytes,
            .alignment = buffer.alignment,
            .binding = binding,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidDataSymbol, error.ConflictingDataSymbol => return error.InvalidArtifact,
        };
        if (self.data.items().len == count) return error.InvalidArtifact;
        std.debug.assert(self.data.indexOf(buffer.name) == count);
    }

    /// Records one call or data relocation and returns its code offset.
    fn addRelocation(
        self: *ArtifactView,
        allocator: std.mem.Allocator,
        relocation: artifact.Relocation,
    ) Error!usize {
        const offset = std.math.cast(usize, relocation.offset) orelse return error.InvalidArtifact;
        if (offset > self.code.len or self.code.len - offset < 8) return error.InvalidArtifact;
        if (relocation.width_bits) |width| if (width != 64) return error.InvalidArtifact;
        switch (relocation.kind) {
            .call => {
                if (relocation.symbol.len == 0) return error.InvalidArtifact;
                if (relocation.addend != 0) return error.InvalidArtifact;
                const call = emit.CallRelocation{ .offset = offset, .target = relocation.symbol };
                try self.calls.append(allocator, call);
            },
            .absolute => {
                if (self.data.indexOf(relocation.symbol) == null) return error.InvalidArtifact;
                try self.data_relocations.append(allocator, .{
                    .offset = offset,
                    .target = relocation.symbol,
                    .addend = relocation.addend,
                });
            },
            else => return error.InvalidArtifact,
        }
        std.debug.assert(offset + 8 <= self.code.len);
        return offset;
    }
};

fn choirDeclAdd1(value: i64) callconv(.c) i64 {
    return value + 1;
}

const artifact_target = artifact.Target{ .architecture = .x86_64 };
const artifact_abi = artifact.Abi{
    .name = "sysv",
    .calling_convention = "c",
    .pointer_width_bits = 64,
    .endianness = .little,
};
const nullary_integer = artifact.Signature.init(&.{}, &.{.{ .scalar = .i64 }}) catch unreachable;

const MalformedDataArtifact = struct {
    data: []const artifact.DataBuffer = &.{table},
    relocations: []const artifact.Relocation = &.{reference},
    orphan_buffer: bool = false,

    const table = artifact.DataBuffer{ .name = "table", .bytes = "\x01\x02" };
    const reference = artifact.Relocation{ .offset = 0, .symbol = "table", .kind = .absolute };
};

const JitIrResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) JitIrResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: JitIrResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn expectEmitterFunctionStateDiscarded(runtime: *const JitRuntime) !void {
    const emitter = &runtime.emitter;
    try std.testing.expectEqual(@as(usize, 0), emitter.code.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.call_relocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.data_symbols.items().len);
    try std.testing.expectEqual(@as(usize, 0), emitter.data_relocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.slot_map.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.vector_slot_map.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.alloca_payload_slots.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.allocation_kinds.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.value_locations.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_index.value_keys.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_index.value_heads.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_index.value_links.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_locations.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_index.value_keys.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_index.value_heads.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_index.value_links.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.operation_positions.count());
}

fn createJitConstantFunction(ctx: *ir.Context, name: []const u8, value: i64) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("temporary-jit.choir", 1, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const constant = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, value);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);
    return func.op;
}

fn createJitCallingFunction(ctx: *ir.Context, name: []const u8, callee: []const u8) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("temporary-jit.choir", 3, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const call = try FuncDialect.CallOp.create(ctx, loc, callee, &.{}, &.{i64_type});
    try entry.addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);
    return func.op;
}

fn createJitConstantModule(ctx: *ir.Context, name: []const u8, value: i64) !*ir.Operation {
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, ir.Location.getUnknown());
    errdefer module.op.erase();
    const function = try createJitConstantFunction(ctx, name, value);
    errdefer function.erase();
    try module.getBodyBlock().addOperation(function);
    return module.op;
}

fn createJitMemrefIdentityModule(ctx: *ir.Context, name: []const u8) !*ir.Operation {
    const i32_type = try dialects.ArithDialect.getScalarType(ctx, .i32);
    const memref_type = try dialects.MemrefDialect.getMemrefType1D(ctx, 4, i32_type, .host);
    const loc = ir.Location.getFile("temporary-jit.choir", 2, 1);
    const types = [_]ir.Type{memref_type};
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &types, &types);
    errdefer function.op.erase();
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{function.getArgument(0)});
    try function.getEntryBlock().addOperation(ret.op);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    try module.getBodyBlock().addOperation(function.op);
    return module.op;
}

/// Appends an integer constant that carries the attributes of `symbol`, so it evaluates to the
/// address of the bytes instead of its value, 7.
fn appendJitDataConstant(
    ctx: *ir.Context,
    block: *ir.Block,
    symbol: machine.DataSymbol,
) !*ir.Value {
    const ArithDialect = dialects.ArithDialect;
    const names = machine.data_symbol_attr_names;
    const loc = ir.Location.getFile("data-jit.choir", 2, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const constant = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 7);
    try block.addOperation(constant.op);
    try constant.op.setAttr(names.name, try ctx.getStringAttr(symbol.name));
    try constant.op.setAttr(names.bytes, try ctx.getStringAttr(symbol.bytes));
    try constant.op.setAttr(names.alignment, try ctx.getI64Attr(@intCast(symbol.alignment)));
    return constant.getResult();
}

/// Builds `name` returning the address of `symbol`.
fn createJitDataFunction(
    ctx: *ir.Context,
    name: []const u8,
    symbol: machine.DataSymbol,
) !*ir.Operation {
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("data-jit.choir", 1, 1);
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const address = try appendJitDataConstant(ctx, entry, symbol);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{address});
    try entry.addOperation(ret.op);
    return func.op;
}

/// Builds `name` returning `(address + delta) - address` for the address of `symbol`.
fn createJitDataDeltaFunction(
    ctx: *ir.Context,
    name: []const u8,
    symbol: machine.DataSymbol,
    delta: i64,
) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("data-jit.choir", 3, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const address = try appendJitDataConstant(ctx, entry, symbol);
    const offset = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, delta);
    try entry.addOperation(offset.op);
    const sum = try ArithDialect.AddOp.create(ctx, loc, address, offset.getResult());
    try entry.addOperation(sum.op);
    const difference = try ArithDialect.SubOp.create(ctx, loc, sum.getResult(), address);
    try entry.addOperation(difference.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{difference.getResult()});
    try entry.addOperation(ret.op);
    return func.op;
}

fn createJitDataModule(
    ctx: *ir.Context,
    name: []const u8,
    symbol: machine.DataSymbol,
) !*ir.Operation {
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, ir.Location.getUnknown());
    errdefer module.op.erase();
    const function = try createJitDataFunction(ctx, name, symbol);
    errdefer function.erase();
    try module.getBodyBlock().addOperation(function);
    return module.op;
}

fn addJitFunction(module: *ir.Operation, function: *ir.Operation) !void {
    errdefer function.erase();
    try module.getRegion(0).?.getEntryBlock().?.addOperation(function);
}

fn addressFrom(runtime: *const JitRuntime, handle: ModuleHandle, name: []const u8) !usize {
    const Address = *const fn () callconv(.c) i64;
    return @intCast((try runtime.getFunction(handle, name, Address))());
}

fn bytesAt(address: usize, len: usize) []const u8 {
    const bytes: [*]const u8 = @ptrFromInt(address);
    return bytes[0..len];
}

fn readProcSelfMaps(allocator: std.mem.Allocator) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/proc/self/maps", .{});
    defer file.close(std.Options.debug_io);
    var maps: std.ArrayList(u8) = .empty;
    errdefer maps.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try sys.fd.read(file.handle, &buffer);
        if (count == 0) break;
        try maps.appendSlice(allocator, buffer[0..count]);
    }
    return try maps.toOwnedSlice(allocator);
}

/// Returns the permission field of the `/proc/self/maps` line whose range holds `address`.
fn mappingPermissions(maps: []const u8, address: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse continue;
        const permissions = fields.next() orelse continue;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = std.fmt.parseInt(usize, range[0..dash], 16) catch continue;
        const end = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch continue;
        if (start <= address and address < end) return permissions;
    }
    return null;
}

test "JitRuntime machine-code artifact failures leave no loaded state" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    const code = @as([16]u8, @splat(0));

    var malformed = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "malformed_entry",
        nullary_integer,
        &code,
        &.{},
        &.{.{ .offset = 12, .symbol = "choir_decl_add1", .kind = .call }},
    );
    defer malformed.deinit();
    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("choir_decl_add1", @intFromPtr(&choirDeclAdd1));
    try testing.expectError(error.InvalidArtifact, runtime.loadMachineCodeArtifact(&malformed));
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);

    var unresolved = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "unresolved_entry",
        nullary_integer,
        &code,
        &.{},
        &.{.{ .offset = 0, .symbol = "missing_external", .kind = .call }},
    );
    defer unresolved.deinit();
    var unresolved_runtime = JitRuntime.init(testing.allocator, .testing);
    defer unresolved_runtime.deinit();
    try testing.expectError(error.SymbolNotFound, unresolved_runtime.loadMachineCodeArtifact(&unresolved));
    try testing.expectEqual(@as(usize, 0), unresolved_runtime.modules.items.len);

    var valid = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "allocation_entry",
        nullary_integer,
        &code,
        &.{.{ .name = "allocation_table", .bytes = "\x01\x02", .alignment = 8 }},
        &.{
            .{ .offset = 0, .symbol = "choir_decl_add1", .kind = .call },
            .{ .offset = 8, .symbol = "allocation_table", .kind = .absolute },
        },
    );
    defer valid.deinit();
    var reached_success = false;
    var fail_offset: usize = 0;
    while (fail_offset < 32) : (fail_offset += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var allocation_runtime = JitRuntime.init(failing.allocator(), .testing);
        defer allocation_runtime.deinit();
        try allocation_runtime.registerExternalSymbol("choir_decl_add1", @intFromPtr(&choirDeclAdd1));
        failing.fail_index = failing.alloc_index + fail_offset;
        if (allocation_runtime.loadMachineCodeArtifact(&valid)) |_| {
            reached_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), allocation_runtime.modules.items.len);
        }
    }
    try testing.expect(reached_success);
}

test "JitRuntime patches data addresses into loaded machine code" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    const movabs_rax = [2]u8{ 0x48, 0xb8 };
    const movabs_rdx = [2]u8{ 0x48, 0xba };
    const ret_opcode = 0xc3;
    const unreached_movabs_rcx = [2]u8{ 0x48, 0xb9 };
    var code = @as([31]u8, @splat(0));
    code[0..2].* = movabs_rax;
    code[10..12].* = movabs_rdx;
    code[20] = ret_opcode;
    code[21..23].* = unreached_movabs_rcx;
    const table = "\x10\x20\x30\x40\x50";
    const page = "page bytes";
    const addresses_signature = try artifact.Signature.init(
        &.{},
        &.{ .{ .scalar = .index }, .{ .scalar = .index } },
    );
    var loadable = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "data_entry",
        addresses_signature,
        &code,
        &.{
            .{ .name = "table", .bytes = table, .alignment = 4 },
            .{ .name = "page", .bytes = page, .alignment = machine.max_data_alignment },
        },
        &.{
            .{ .offset = 2, .symbol = "table", .kind = .absolute, .addend = 3 },
            .{ .offset = 12, .symbol = "page", .kind = .absolute },
            .{ .offset = 23, .symbol = "data_entry", .kind = .call },
        },
    );
    defer loadable.deinit();

    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.loadMachineCodeArtifact(&loadable);
    const Addresses = extern struct { table: usize, page: usize };
    const Entry = *const fn () callconv(.c) Addresses;
    const entry = try runtime.getFunction(handle, "data_entry", Entry);
    const addresses = entry();
    const table_address = addresses.table - 3;
    try testing.expect(std.mem.isAligned(table_address, 4));
    try testing.expectEqualSlices(u8, table, bytesAt(table_address, table.len));
    try testing.expect(std.mem.isAligned(addresses.page, machine.max_data_alignment));
    try testing.expectEqualSlices(u8, page, bytesAt(addresses.page, page.len));

    const entry_address = try runtime.functionAddress(handle, "data_entry");
    const self_call = bytesAt(entry_address + 23, 8)[0..8];
    try testing.expectEqual(@as(u64, entry_address), std.mem.readInt(u64, self_call, .little));
}

test "JitRuntime rejects malformed data artifacts" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    const code = @as([16]u8, @splat(0));
    const table = MalformedDataArtifact.table;
    const reference = MalformedDataArtifact.reference;
    const narrow_window = artifact.Relocation{
        .offset = 0,
        .symbol = "table",
        .kind = .absolute,
        .width_bits = 32,
    };
    const call_with_addend = artifact.Relocation{
        .offset = 0,
        .symbol = "choir_decl_add1",
        .kind = .call,
        .addend = 1,
    };
    const cases = [_]MalformedDataArtifact{
        .{ .relocations = &.{.{ .offset = 0, .symbol = "missing", .kind = .absolute }} },
        .{ .relocations = &.{.{ .offset = 0, .symbol = "malformed_entry", .kind = .absolute }} },
        .{ .data = &.{ table, .{ .name = "malformed_entry", .bytes = "\x03" } } },
        .{ .data = &.{.{ .name = "table", .bytes = "\x01\x02", .alignment = 3 }} },
        .{ .data = &.{.{ .name = "table", .bytes = "" }} },
        .{ .data = &.{.{ .name = "table", .bytes = "\x01\x02", .binding = .weak }} },
        .{ .data = &.{ table, table } },
        .{ .relocations = &.{ reference, .{ .offset = 4, .symbol = "table", .kind = .absolute } } },
        .{ .relocations = &.{.{ .offset = 9, .symbol = "table", .kind = .absolute }} },
        .{ .relocations = &.{narrow_window} },
        .{ .relocations = &.{call_with_addend} },
        .{ .relocations = &.{.{ .offset = 0, .symbol = "table", .kind = .unknown }} },
        .{ .orphan_buffer = true },
    };

    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("choir_decl_add1", @intFromPtr(&choirDeclAdd1));
    for (cases) |case| {
        var malformed = try artifact.machineCodeArtifact(
            testing.allocator,
            artifact_target,
            artifact_abi,
            "malformed_entry",
            nullary_integer,
            &code,
            case.data,
            case.relocations,
        );
        defer malformed.deinit();
        if (case.orphan_buffer) {
            try malformed.payload.addBuffer(.{ .name = "orphan", .format = .raw, .bytes = "\x03" });
        }
        try testing.expectError(error.InvalidArtifact, runtime.loadMachineCodeArtifact(&malformed));
        try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    }
}

test "JitRuntime refuses artifacts without a signature it can call" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    const code = @as([16]u8, @splat(0xc3));
    const lanes = artifact.ValueType{ .vector = .{ .element = .f32, .lanes = 4 } };
    var no_lanes = try artifact.Signature.init(&.{}, &.{lanes});
    no_lanes.result_types[0].vector.lanes = 0;
    const refused = [_]?artifact.Signature{
        null,
        try artifact.Signature.init(&.{lanes}, &.{}),
        try artifact.Signature.init(&.{}, &.{ lanes, .{ .scalar = .f32 } }),
        no_lanes,
    };
    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    for (refused) |signature| {
        var unsigned = try artifact.machineCodeArtifact(
            testing.allocator,
            artifact_target,
            artifact_abi,
            "entry",
            nullary_integer,
            &code,
            &.{},
            &.{},
        );
        defer unsigned.deinit();
        unsigned.linkage.provided_symbols.items[0].signature = signature;
        try testing.expectError(error.InvalidArtifact, runtime.loadMachineCodeArtifact(&unsigned));
        try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    }
}

test "JitRuntime failed compiles keep previously compiled modules" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const kept_module = try createJitConstantModule(&ctx, "kept", 7);
    defer kept_module.erase();
    const staged_module = try createJitConstantModule(&ctx, "staged", 8);
    defer staged_module.erase();
    const staged_table = machine.DataSymbol{
        .name = "staged_table",
        .bytes = "staged bytes",
        .alignment = 8,
    };
    const table_function = try createJitDataFunction(&ctx, "staged_table", staged_table);
    try addJitFunction(staged_module, table_function);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    const Constant = *const fn () callconv(.c) i64;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var runtime = JitRuntime.init(failing.allocator(), .testing);
    defer runtime.deinit();
    const kept = try runtime.compile(kept_module);
    const kept_value = try runtime.getFunction(kept, "kept", Constant);

    var reached_success = false;
    var fail_offset: usize = 0;
    while (fail_offset < 128) : (fail_offset += 1) {
        failing.fail_index = failing.alloc_index + fail_offset;
        if (runtime.compile(staged_module)) |staged| {
            failing.fail_index = std.math.maxInt(usize);
            const staged_value = try runtime.getFunction(staged, "staged", Constant);
            try testing.expectEqual(@as(i64, 8), staged_value());
            const table_address = try addressFrom(&runtime, staged, "staged_table");
            const table_bytes = bytesAt(table_address, staged_table.bytes.len);
            try testing.expectEqualStrings(staged_table.bytes, table_bytes);
            reached_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try expectEmitterFunctionStateDiscarded(&runtime);
            try testing.expectEqual(@as(usize, 1), runtime.modules.items.len);
            try testing.expectEqual(@as(i64, 7), kept_value());
        }
    }
    try testing.expect(reached_success);
    try testing.expectEqual(@as(i64, 7), kept_value());
    try testing.expectEqual(@as(usize, 0), reports.diagnostics.items.len);
}

test "JitRuntime data pages stay read-only and outlive released modules" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const first_table = machine.DataSymbol{ .name = "table", .bytes = "first", .alignment = 16 };
    const first_module = try createJitDataModule(&ctx, "table", first_table);
    defer first_module.erase();
    const second_table = machine.DataSymbol{ .name = "table", .bytes = "second" };
    const second_module = try createJitDataModule(&ctx, "table", second_table);
    defer second_module.erase();

    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const first = try runtime.compile(first_module);
    const second = try runtime.compile(second_module);
    const first_address = try addressFrom(&runtime, first, "table");
    const second_address = try addressFrom(&runtime, second, "table");
    try testing.expect(std.mem.isAligned(first_address, 16));
    try testing.expectEqualStrings("first", bytesAt(first_address, 5));
    try testing.expectEqualStrings("second", bytesAt(second_address, 6));

    if (comptime @import("builtin").os.tag == .linux) {
        const maps = try readProcSelfMaps(testing.allocator);
        defer testing.allocator.free(maps);
        try testing.expectEqualStrings("r--p", mappingPermissions(maps, first_address).?);
        const code_address = try runtime.functionAddress(first, "table");
        try testing.expectEqualStrings("r-xp", mappingPermissions(maps, code_address).?);
    }

    try runtime.release(first);
    try testing.expectEqualStrings("second", bytesAt(second_address, 6));
    const reloaded = try runtime.compile(first_module);
    try testing.expectEqual(first.index, reloaded.index);
    const reloaded_address = try addressFrom(&runtime, reloaded, "table");
    try testing.expectEqualStrings("first", bytesAt(reloaded_address, 5));
}

test "JitRuntime modules share equal data symbols and refuse conflicting ones" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const table = machine.DataSymbol{ .name = "table", .bytes = "shared" };
    const shared = try createJitDataModule(&ctx, "first", table);
    defer shared.erase();
    try addJitFunction(shared, try createJitDataFunction(&ctx, "second", table));
    try addJitFunction(shared, try createJitDataDeltaFunction(&ctx, "delta", table, 5));

    const Value = *const fn () callconv(.c) i64;
    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(shared);
    const first = (try runtime.getFunction(handle, "first", Value))();
    try testing.expectEqual(first, (try runtime.getFunction(handle, "second", Value))());
    try testing.expectEqual(@as(i64, 5), (try runtime.getFunction(handle, "delta", Value))());

    const conflicting = try createJitDataModule(&ctx, "first", table);
    defer conflicting.erase();
    const different = machine.DataSymbol{ .name = "table", .bytes = "different" };
    const second = try createJitDataFunction(&ctx, "second", different);
    try addJitFunction(conflicting, second);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();
    try testing.expectError(error.ConflictingDataSymbol, runtime.compile(conflicting));
    try testing.expectEqual(@as(usize, 1), runtime.modules.items.len);
    try expectEmitterFunctionStateDiscarded(&runtime);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    try testing.expectEqual(second, reports.diagnostics.items[0].operation.?);
}

test "JitRuntime modules outlive their IR until released" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();

    var constants: ModuleHandle = undefined;
    var identity: ModuleHandle = undefined;
    const identity_name = "temporary_memref_identity";
    {
        var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const resource_baseline = JitIrResourceCounts.capture(&ctx);

        const module = try createJitConstantModule(&ctx, "temporary_first", 41);
        var module_owned = true;
        errdefer if (module_owned) module.erase();
        const caller = try createJitCallingFunction(&ctx, "temporary_caller", "temporary_first");
        try module.getRegion(0).?.getEntryBlock().?.addOperation(caller);
        constants = try runtime.compile(module);
        try expectEmitterFunctionStateDiscarded(&runtime);
        module.erase();
        module_owned = false;
        try resource_baseline.expectEqual(&ctx);

        const identity_module = try createJitMemrefIdentityModule(&ctx, identity_name);
        var identity_owned = true;
        errdefer if (identity_owned) identity_module.erase();
        identity = try runtime.compile(identity_module);
        try expectEmitterFunctionStateDiscarded(&runtime);
        identity_module.erase();
        identity_owned = false;
        try resource_baseline.expectEqual(&ctx);
    }

    const Constant = *const fn () callconv(.c) i64;
    const first_entry = try runtime.getFunction(constants, "temporary_first", Constant);
    try testing.expectEqual(@as(i64, 41), first_entry());
    const caller_entry = try runtime.getFunction(constants, "temporary_caller", Constant);
    try testing.expectEqual(@as(i64, 41), caller_entry());
    const first_signature = try runtime.functionSignature(constants, "temporary_first");
    try testing.expect(first_signature.eql(&nullary_integer));

    const memref_identity = try artifact.Signature.init(&.{.memref}, &.{.memref});
    const identity_signature = try runtime.functionSignature(identity, identity_name);
    try testing.expect(identity_signature.eql(&memref_identity));
    const Identity = *const fn (*anyopaque) callconv(.c) *anyopaque;
    const identity_entry = try runtime.getFunction(identity, identity_name, Identity);
    const address: *anyopaque = @ptrFromInt(0x1234_5678);
    try testing.expectEqual(address, identity_entry(address));

    try runtime.release(constants);
    const released = runtime.getFunction(constants, "temporary_first", Constant);
    try testing.expectError(error.InvalidModuleHandle, released);
    try testing.expectError(error.InvalidModuleHandle, runtime.release(constants));
    const low: *anyopaque = @ptrFromInt(0x42);
    try testing.expectEqual(low, identity_entry(low));
    try runtime.release(identity);
    for (runtime.modules.items) |module| try testing.expect(!module.live);
}

test "JitRuntime recompiles keep handed-out code until release" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const one = try createJitConstantModule(&ctx, "value", 1);
    defer one.erase();
    const two = try createJitConstantModule(&ctx, "value", 2);
    defer two.erase();

    const Value = *const fn () callconv(.c) i64;
    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const first = try runtime.compile(one);
    const first_value = try runtime.getFunction(first, "value", Value);
    const second = try runtime.compile(two);
    try testing.expectEqual(@as(i64, 1), first_value());
    try testing.expectEqual(@as(i64, 2), (try runtime.getFunction(second, "value", Value))());

    try runtime.release(first);
    const third = try runtime.compile(one);
    try testing.expectEqual(first.index, third.index);
    try testing.expect(first.generation != third.generation);
    try testing.expectError(error.InvalidModuleHandle, runtime.functionAddress(first, "value"));
    try testing.expectEqual(@as(i64, 1), (try runtime.getFunction(third, "value", Value))());
    try testing.expectEqual(@as(i64, 2), (try runtime.getFunction(second, "value", Value))());
    try testing.expectError(error.FunctionNotFound, runtime.functionAddress(third, "missing"));
    const unissued = ModuleHandle{ .index = 2, .generation = 1 };
    try testing.expectError(error.InvalidModuleHandle, runtime.functionAddress(unissued, "value"));
}

test "JIT patches extern call targets for memref alloc/free" {
    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "memref_roundtrip", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(size.op);

    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    const dealloc = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc.getResult());
    try entry.addOperation(dealloc.op);

    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(zero.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{zero.getResult()});
    try entry.addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ir_ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.SymbolNotFound, runtime.compile(module.op));
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    try testing.expectEqual(func.op, reports.diagnostics.items[0].operation.?);
    try runtime.registerExternalSymbol("malloc", @intFromPtr(&sys.heap.malloc));
    try runtime.registerExternalSymbol("free", @intFromPtr(&sys.heap.free));
    const handle = try runtime.compile(module.op);

    const compiled = runtime.modules.items[handle.index];
    const function = compiled.functions.get("memref_roundtrip") orelse return error.FunctionNotFound;
    const code = compiled.code.?[function.offset..][0..function.size];

    var malloc_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, malloc_bytes[0..], @intCast(@intFromPtr(&sys.heap.malloc)), .little);
    var free_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, free_bytes[0..], @intCast(@intFromPtr(&sys.heap.free)), .little);

    try testing.expect(std.mem.indexOf(u8, code, malloc_bytes[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, code, free_bytes[0..]) != null);
}

test "JIT treats bodyless func declarations as extern symbols" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_decl_add1";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        decl_name,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);

    var caller = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_decl", &.{}, &.{i64_type});
    try module_block.addOperation(caller.op);

    const entry = caller.getEntryBlock();
    var forty_one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 41);
    try entry.addOperation(forty_one.op);

    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{forty_one.getResult()}, &.{i64_type});
    try entry.addOperation(call.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&choirDeclAdd1));
    const handle = try runtime.compile(module.op);

    try testing.expectError(error.FunctionNotFound, runtime.functionAddress(handle, decl_name));
    const entry_fn = try runtime.getFunction(handle, "call_decl", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), entry_fn());
}

test "JIT requires explicit extern symbol registration" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_unregistered_external";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        decl_name,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);

    var caller = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_unregistered_decl", &.{}, &.{i64_type});
    try module_block.addOperation(caller.op);

    const entry = caller.getEntryBlock();
    var forty_one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 41);
    try entry.addOperation(forty_one.op);

    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{forty_one.getResult()}, &.{i64_type});
    try entry.addOperation(call.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ir_ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.SymbolNotFound, runtime.compile(module.op));
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const unresolved = reports.diagnostics.items[0];
    try testing.expectEqual(call.op, unresolved.operation.?);
    try testing.expectEqualStrings(failures.Stage.link.name(), unresolved.metadata[0].value);

    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&choirDeclAdd1));
    const handle = try runtime.compile(module.op);
    const entry_fn = try runtime.getFunction(handle, "call_unregistered_decl", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), entry_fn());
}

test "JitRuntime rejects functions beyond the result record bound" {
    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    var results: [abi.max_result_count + 1]ir.Type = undefined;
    @memset(&results, i64_type);
    const wide = try FuncDialect.FuncOp.create(&ctx, loc, "wide", &.{i64_type}, &results);
    try module.getBodyBlock().addOperation(wide.op);
    var operands: [results.len]*ir.Value = undefined;
    @memset(&operands, wide.getArgument(0));
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &operands);
    try wide.getEntryBlock().addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.TooManyResults, runtime.compile(module.op));
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const rejected = reports.diagnostics.items[0];
    try testing.expectEqual(wide.op, rejected.operation.?);
    try testing.expectEqualStrings(failures.Stage.emit.name(), rejected.metadata[0].value);
}

test "JitRuntime locates emission failures at the innermost failing operation" {
    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getFile("failing-jit.choir", 5, 3);
    const u64_type = try ArithDialect.getScalarType(&ctx, .u64);
    const module = try createJitConstantModule(&ctx, "kept", 7);
    const function = try FuncDialect.FuncOp.create(&ctx, loc, "shift", &.{}, &.{u64_type});
    try addJitFunction(module, function.op);
    const entry = function.getEntryBlock();
    const value = try ArithDialect.ConstantOp.createInt(&ctx, loc, u64_type, 16);
    try entry.addOperation(value.op);
    const condition = try ArithDialect.ConstantOp.createBool(&ctx, loc, true);
    try entry.addOperation(condition.op);
    const branch = try ScfDialect.IfOp.create(&ctx, loc, condition.getResult(), &.{u64_type});
    try entry.addOperation(branch.op);
    const shift = try ArithDialect.ShrOp.create(&ctx, loc, value.getResult(), value.getResult());
    try branch.getThenBlock().addOperation(shift.op);
    const shifted = try ScfDialect.YieldOp.create(&ctx, loc, &.{shift.getResult()});
    try branch.getThenBlock().addOperation(shifted.op);
    const unshifted = try ScfDialect.YieldOp.create(&ctx, loc, &.{value.getResult()});
    try branch.getElseBlock().?.addOperation(unshifted.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{branch.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.UnsupportedType, runtime.compile(module));
    try expectEmitterFunctionStateDiscarded(&runtime);
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const rejected = reports.diagnostics.items[0];
    try testing.expectEqual(shift.op, rejected.operation.?);
    try testing.expectEqualStrings(failures.Stage.emit.name(), rejected.metadata[0].value);
}

test "JitRuntime function addresses survive module list growth" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try createJitConstantModule(&ctx, "entry", 5);
    defer module.erase();

    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const first = try runtime.compile(module);
    const before = try runtime.functionAddress(first, "entry");
    for (0..8) |_| _ = try runtime.compile(module);
    try testing.expectEqual(before, try runtime.functionAddress(first, "entry"));
    const entry = try runtime.getFunction(first, "entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 5), entry());
}

test "JitRuntime admits modules up to its module count and rejects the next" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try createJitConstantModule(&ctx, "entry", 7);
    defer module.erase();

    const limit = 3;
    var runtime = JitRuntime.init(testing.allocator, .{
        .live_modules = limit,
        .mapped_bytes = JitRuntime.Limits.testing.mapped_bytes,
    });
    defer runtime.deinit();

    var handles: [limit]ModuleHandle = undefined;
    for (&handles) |*handle| handle.* = try runtime.compile(module);
    try testing.expectEqual(@as(u32, limit), runtime.live_modules);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    try runtime.release(handles[1]);
    try testing.expectEqual(@as(u32, limit - 1), runtime.live_modules);
    handles[1] = try runtime.compile(module);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    try testing.expectEqual(@as(u32, 1), handles[1].index);
    try testing.expectEqual(@as(u32, 2), handles[1].generation);
    try testing.expectEqual(@as(usize, limit), runtime.modules.items.len);

    const entry = try runtime.getFunction(handles[0], "entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 7), entry());
}

test "JitRuntime admits modules up to its mapped-byte budget and rejects the next" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try createJitConstantModule(&ctx, "entry", 9);
    defer module.erase();

    const bytes_per_module = sys.memory.pageAlign(1).?;
    const admitted_modules = 3;
    const budget: u64 = admitted_modules * bytes_per_module;
    var runtime = JitRuntime.init(testing.allocator, .{
        .live_modules = JitRuntime.Limits.testing.live_modules,
        .mapped_bytes = budget,
    });
    defer runtime.deinit();

    var handles: [admitted_modules]ModuleHandle = undefined;
    for (&handles) |*handle| handle.* = try runtime.compile(module);
    try testing.expectEqual(budget, runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, admitted_modules), runtime.live_modules);

    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));
    try testing.expectEqual(budget, runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, admitted_modules), runtime.live_modules);

    try runtime.release(handles[1]);
    try testing.expectEqual(budget - bytes_per_module, runtime.mapped_bytes);
    handles[1] = try runtime.compile(module);
    try testing.expectEqual(budget, runtime.mapped_bytes);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    const entry = try runtime.getFunction(handles[0], "entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 9), entry());
}

test "JitRuntime charges a module's data mapping alongside its code" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const table = machine.DataSymbol{ .name = "table", .bytes = "payload" };
    const module = try createJitDataModule(&ctx, "table", table);
    defer module.erase();

    const page = sys.memory.pageAlign(1).?;
    var runtime = JitRuntime.init(testing.allocator, .testing);
    defer runtime.deinit();

    const handle = try runtime.compile(module);
    try testing.expectEqual(@as(u64, 2 * page), runtime.mapped_bytes);
    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "JitRuntime counts a data mapping against the mapped-byte budget" {
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const table = machine.DataSymbol{ .name = "table", .bytes = "payload" };
    const module = try createJitDataModule(&ctx, "table", table);
    defer module.erase();

    const page = sys.memory.pageAlign(1).?;
    var runtime = JitRuntime.init(testing.allocator, .{
        .live_modules = JitRuntime.Limits.testing.live_modules,
        .mapped_bytes = 2 * page,
    });
    defer runtime.deinit();

    const handle = try runtime.compile(module);
    try testing.expectEqual(@as(u64, 2 * page), runtime.mapped_bytes);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
    const again = try runtime.compile(module);
    try testing.expectEqual(@as(u64, 2 * page), runtime.mapped_bytes);
    try runtime.release(again);
}

test "JIT debug map includes line locations" {
    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getFile("test.choir", 4, 2);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "debug_map", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var constant = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 7);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const emitted = try runtime.writeDebugMap(&writer);
    const output = writer.buffered();

    try testing.expect(emitted);
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "debug_map"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "test.choir:4:2"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "arith.constant"));

    try runtime.release(handle);
    var released_writer = std.Io.Writer.fixed(&buf);
    try testing.expect(!try runtime.writeDebugMap(&released_writer));
}

test "JIT debug map is best-effort when registration fails" {
    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    if (!debug_info.supportsJitDebugInfo(sys.capabilities.current.arch)) {
        return error.SkipZigTest;
    }

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();

    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getFile("test.choir", 1, 1);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "debug_map_fail", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var constant = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    _ = try runtime.compile(module.op);

    failing.fail_index = failing.alloc_index;

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const emitted = try runtime.writeDebugMap(&writer);
    const output = writer.buffered();

    try testing.expect(emitted);
    try testing.expect(failing.has_induced_failure);
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "debug_map_fail"));
}

/// Linux x86-64 kernel entry numbers and arguments the two tests below enter the kernel with.
/// They are named here rather than read from a host namespace because Choir owns no host
/// surface, and because a wrong number fails the test that uses it: `getpid` answers a pid this
/// process can check, and `rt_sigprocmask` answers zero only when it read a whole signal set.
const linux_getpid: i64 = 39;
const linux_rt_sigprocmask: i64 = 14;
const linux_sig_setmask: i64 = 2;
const linux_signal_set_bytes: i64 = 8;
const linux_efault: i64 = -14;
const linux_einval: i64 = -22;

test "JIT enters the kernel through a func.syscall" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }
    if (!sys.capabilities.current.isLinux()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "syscall_getpid", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var number = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, linux_getpid);
    try entry.addOperation(number.op);
    const entered = try FuncDialect.SyscallOp.create(&ir_ctx, loc, number.getResult(), &.{}, i64_type);
    try entry.addOperation(entered.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{entered.getResult()});
    try entry.addOperation(ret.op);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const entry_fn = try runtime.getFunction(handle, "syscall_getpid", *const fn () callconv(.c) i64);

    const expected: i64 = try sys.process.currentProcessId();
    try testing.expectEqual(expected, entry_fn());
}

test "JIT passes a func.syscall argument three in r10" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }
    if (!sys.capabilities.current.isLinux()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(
        &ir_ctx,
        loc,
        "syscall_read_signal_mask",
        &.{ i64_type, i64_type },
        &.{i64_type},
    );
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var number = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, linux_rt_sigprocmask);
    try entry.addOperation(number.op);
    var how = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, linux_sig_setmask);
    try entry.addOperation(how.op);
    var no_new_mask = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(no_new_mask.op);

    const arguments = [_]*ir.Value{
        how.getResult(),
        no_new_mask.getResult(),
        func.getArgument(0),
        func.getArgument(1),
    };
    const entered = try FuncDialect.SyscallOp.create(&ir_ctx, loc, number.getResult(), &arguments, i64_type);
    try entry.addOperation(entered.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{entered.getResult()});
    try entry.addOperation(ret.op);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const entry_fn = try runtime.getFunction(
        handle,
        "syscall_read_signal_mask",
        *const fn (i64, i64) callconv(.c) i64,
    );

    var observed: u64 = 0;
    const address: i64 = @intCast(@intFromPtr(&observed));

    try testing.expectEqual(@as(i64, 0), entry_fn(address, linux_signal_set_bytes));
    try testing.expectEqual(linux_einval, entry_fn(address, linux_signal_set_bytes - 1));
    try testing.expectEqual(linux_efault, entry_fn(1, linux_signal_set_bytes));
}

/// A constant global's bytes, as two words whose bytes a wrong offset would not reproduce.
const pin_table_words = [_]u64{ 0x0102030405060708, 0x1122334455667788 };
const pin_table_bytes: []const u8 = std.mem.asBytes(&pin_table_words);

/// Builds a module with one zeroed global the code writes and one constant global it reads.
fn buildGlobalModule(ir_ctx: *ir.Context) !dialects.BuiltinDialect.ModuleOp {
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const word_type = try MemrefDialect.getMemrefType1D(ir_ctx, 1, i64_type, .host);
    const table_type = try MemrefDialect.getMemrefType1D(ir_ctx, 2, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const count = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "count",
        .memref_type = word_type,
        .alignment = 8,
    });
    try module_block.addOperation(count.op);
    const table = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "table",
        .memref_type = table_type,
        .alignment = 8,
        .constant = true,
        .initial = pin_table_bytes,
    });
    try module_block.addOperation(table.op);

    var next = try FuncDialect.FuncOp.create(ir_ctx, loc, "next", &.{}, &.{i64_type});
    try module_block.addOperation(next.op);
    {
        const entry = next.getEntryBlock();
        var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const count_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "count", word_type);
        try entry.addOperation(count_ref.op);
        var used = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            count_ref.getResult(),
            zero.getResult(),
            i64_type,
        );
        try entry.addOperation(used.op);
        var one = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 1);
        try entry.addOperation(one.op);
        const raised = try ArithDialect.AddOp.create(ir_ctx, loc, used.getResult(), one.getResult());
        try entry.addOperation(raised.op);
        const stored = try MemrefDialect.StoreOp.create(
            ir_ctx,
            loc,
            raised.getResult(),
            count_ref.getResult(),
            zero.getResult(),
        );
        try entry.addOperation(stored.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{used.getResult()});
        try entry.addOperation(ret.op);
    }

    var entry_of = try FuncDialect.FuncOp.create(ir_ctx, loc, "entry_of", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(entry_of.op);
    {
        const entry = entry_of.getEntryBlock();
        const table_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "table", table_type);
        try entry.addOperation(table_ref.op);
        var word = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            table_ref.getResult(),
            entry_of.getArgument(0),
            i64_type,
        );
        try entry.addOperation(word.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{word.getResult()});
        try entry.addOperation(ret.op);
    }

    return module;
}

test "JIT resolves a zeroed global and a constant one to storage" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const module = try buildGlobalModule(&ir_ctx);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const next = try runtime.getFunction(handle, "next", *const fn () callconv(.c) i64);
    const entry_of = try runtime.getFunction(handle, "entry_of", *const fn (i64) callconv(.c) i64);

    try testing.expectEqual(@as(i64, 0), next());
    try testing.expectEqual(@as(i64, 1), next());
    try testing.expectEqual(@as(i64, 2), next());

    for (pin_table_words, 0..) |word, index| {
        try testing.expectEqual(word, @as(u64, @bitCast(entry_of(@intCast(index)))));
    }
}

/// The region the module-region pin declares, in bytes.
const pin_arena_capacity: u64 = 4096;
/// The width of the cursor word and of each value the pin promotes.
const pin_word_bytes: i64 = 8;
/// Values whose every byte differs, so reading the region back one byte at a time says which
/// bytes the store reached and where they landed.
const pin_values = [_]i64{
    @bitCast(@as(u64, 0x1122334455667788)),
    @bitCast(@as(u64, 0x99aabbccddeeff01)),
    @bitCast(@as(u64, 0x0123456789abcdef)),
};

/// Builds the module the module-region pin runs: two zero filled globals and three functions
/// over them.
///
/// `bump` is the promotion. `peek` and `cursor` read the result back without going through
/// `memref.view`, so a view that computed the wrong address cannot agree with itself and pass.
/// `peek` loads from the byte base, which the backend emits as a zero extending one byte load,
/// so the caller reassembles a word from eight of them rather than trusting one load to be wide.
fn buildRegionModule(ir_ctx: *ir.Context) !dialects.BuiltinDialect.ModuleOp {
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const u8_type = try ArithDialect.getScalarType(ir_ctx, .u8);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const arena_type = try MemrefDialect.getMemrefType1D(ir_ctx, pin_arena_capacity, u8_type, .host);
    const word_type = try MemrefDialect.getMemrefType1D(ir_ctx, 1, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const backing = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "arena",
        .memref_type = arena_type,
        .alignment = 16,
    });
    try module_block.addOperation(backing.op);
    const cursor_global = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "arena.cursor",
        .memref_type = word_type,
        .alignment = 8,
    });
    try module_block.addOperation(cursor_global.op);

    var bump = try FuncDialect.FuncOp.create(ir_ctx, loc, "bump", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(bump.op);
    {
        const entry = bump.getEntryBlock();
        var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const cursor_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena.cursor", word_type);
        try entry.addOperation(cursor_ref.op);
        var used = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            cursor_ref.getResult(),
            zero.getResult(),
            i64_type,
        );
        try entry.addOperation(used.op);
        const arena_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena", arena_type);
        try entry.addOperation(arena_ref.op);
        const slot = try MemrefDialect.ViewOp.create(
            ir_ctx,
            loc,
            arena_ref.getResult(),
            used.getResult(),
            word_type,
        );
        try entry.addOperation(slot.op);
        const written = try MemrefDialect.StoreOp.create(
            ir_ctx,
            loc,
            bump.getArgument(0),
            slot.getResult(),
            zero.getResult(),
        );
        try entry.addOperation(written.op);
        var width = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, pin_word_bytes);
        try entry.addOperation(width.op);
        const next = try ArithDialect.AddOp.create(ir_ctx, loc, used.getResult(), width.getResult());
        try entry.addOperation(next.op);
        const advanced = try MemrefDialect.StoreOp.create(
            ir_ctx,
            loc,
            next.getResult(),
            cursor_ref.getResult(),
            zero.getResult(),
        );
        try entry.addOperation(advanced.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{used.getResult()});
        try entry.addOperation(ret.op);
    }

    var peek = try FuncDialect.FuncOp.create(ir_ctx, loc, "peek", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(peek.op);
    {
        const entry = peek.getEntryBlock();
        const arena_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena", arena_type);
        try entry.addOperation(arena_ref.op);
        var byte = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            arena_ref.getResult(),
            peek.getArgument(0),
            i64_type,
        );
        try entry.addOperation(byte.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{byte.getResult()});
        try entry.addOperation(ret.op);
    }

    var cursor = try FuncDialect.FuncOp.create(ir_ctx, loc, "cursor", &.{}, &.{i64_type});
    try module_block.addOperation(cursor.op);
    {
        const entry = cursor.getEntryBlock();
        var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const cursor_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena.cursor", word_type);
        try entry.addOperation(cursor_ref.op);
        var used = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            cursor_ref.getResult(),
            zero.getResult(),
            i64_type,
        );
        try entry.addOperation(used.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{used.getResult()});
        try entry.addOperation(ret.op);
    }

    return module;
}

/// Reassembles the little endian word at `offset` from eight one byte reads of the region.
fn readRegionWord(peek: *const fn (i64) callconv(.c) i64, offset: i64) u64 {
    var word: u64 = 0;
    for (0..8) |index| {
        const byte: u64 = @intCast(peek(offset + @as(i64, @intCast(index))));
        std.debug.assert(byte <= 0xff);
        word |= byte << @intCast(index * 8);
    }
    return word;
}

test "JIT promotes into a module region through writable globals" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const module = try buildRegionModule(&ir_ctx);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const bump = try runtime.getFunction(handle, "bump", *const fn (i64) callconv(.c) i64);
    const peek = try runtime.getFunction(handle, "peek", *const fn (i64) callconv(.c) i64);
    const cursor = try runtime.getFunction(handle, "cursor", *const fn () callconv(.c) i64);

    try testing.expectEqual(@as(i64, 0), cursor());
    for (pin_values, 0..) |value, index| {
        const expected: i64 = @intCast(index * @as(usize, @intCast(pin_word_bytes)));
        try testing.expectEqual(expected, bump(value));
    }
    try testing.expectEqual(@as(i64, 24), cursor());

    for (pin_values, 0..) |value, index| {
        const offset: i64 = @intCast(index * @as(usize, @intCast(pin_word_bytes)));
        try testing.expectEqual(@as(u64, @bitCast(value)), readRegionWord(peek, offset));
    }
    try testing.expectEqual(@as(u64, 0), readRegionWord(peek, 24));
}

/// The values the live-across-a-call fixture carries past its call, and the argument it passes.
///
/// Four rather than one, because one could survive by luck in whichever register the callee
/// happened not to touch. Four is more than the callee's own working set, so a call site that
/// left them in volatile registers would lose at least one of them.
const across_addends = [_]i64{ 7, 9, 11, 13 };
const across_argument: i64 = 5;

/// Builds a function whose values are live across a call without being arguments to it.
///
/// `callee` writes every volatile register it can reach by doing arithmetic, so if the call site
/// were responsible for preserving a live value and stopped doing it, the sum below would come
/// back wrong rather than merely slower.
fn buildAcrossModule(ir_ctx: *ir.Context) !dialects.BuiltinDialect.ModuleOp {
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var callee = try FuncDialect.FuncOp.create(ir_ctx, loc, "callee", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(callee.op);
    {
        const entry = callee.getEntryBlock();
        var running = callee.getArgument(0);
        for (across_addends) |addend| {
            var step = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, addend);
            try entry.addOperation(step.op);
            const sum = try ArithDialect.AddOp.create(ir_ctx, loc, running, step.getResult());
            try entry.addOperation(sum.op);
            running = sum.getResult();
        }
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{running});
        try entry.addOperation(ret.op);
    }

    var across = try FuncDialect.FuncOp.create(ir_ctx, loc, "across", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(across.op);
    {
        const entry = across.getEntryBlock();
        var live: [across_addends.len]*ir.Value = undefined;
        for (across_addends, 0..) |addend, index| {
            var step = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, addend);
            try entry.addOperation(step.op);
            const sum = try ArithDialect.AddOp.create(
                ir_ctx,
                loc,
                across.getArgument(0),
                step.getResult(),
            );
            try entry.addOperation(sum.op);
            live[index] = sum.getResult();
        }

        const call = try FuncDialect.CallOp.create(
            ir_ctx,
            loc,
            "callee",
            &.{across.getArgument(0)},
            &.{i64_type},
        );
        try entry.addOperation(call.op);

        var total = call.getResult(0).?;
        for (live) |value| {
            const sum = try ArithDialect.AddOp.create(ir_ctx, loc, total, value);
            try entry.addOperation(sum.op);
            total = sum.getResult();
        }
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{total});
        try entry.addOperation(ret.op);
    }

    return module;
}

test "JIT keeps values live across a call without the call site saving them" {
    if (!sys.capabilities.current.supportsX86_64Execution()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const module = try buildAcrossModule(&ir_ctx);

    var runtime = JitRuntime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const across = try runtime.getFunction(handle, "across", *const fn (i64) callconv(.c) i64);

    var expected: i64 = across_argument;
    for (across_addends) |addend| expected += addend;
    for (across_addends) |addend| expected += across_argument + addend;

    try testing.expectEqual(expected, across(across_argument));
}

test "JitRuntime admits external symbols at each preset and refuses one past" {
    const testing = std.testing;
    for ([_]JitRuntime.Limits{ .testing, .standard }) |limits| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var runtime = JitRuntime.init(failing.allocator(), limits);
        defer runtime.deinit();
        var name: [32]u8 = undefined;
        for (0..limits.external_symbols) |index| {
            const symbol = try std.fmt.bufPrint(&name, "external_{d}", .{index});
            try runtime.registerExternalSymbol(symbol, index + 1);
        }
        try testing.expectEqual(limits.external_symbols, runtime.external_symbols.count());
        const bytes = failing.allocated_bytes - failing.freed_bytes;
        const allocations = failing.alloc_index;
        const metadata = runtime.external_symbols.metadata;
        const table_capacity = runtime.external_symbols.capacity();
        const first = runtime.external_symbols.getEntry("external_0").?;
        const first_name = first.key_ptr.*.ptr;

        try testing.expectError(
            error.JitRuntimeFull,
            runtime.registerExternalSymbol("one_past", 1),
        );
        try testing.expectEqual(limits.external_symbols, runtime.external_symbols.count());
        try testing.expect(!runtime.external_symbols.contains("one_past"));
        try testing.expectEqual(bytes, failing.allocated_bytes - failing.freed_bytes);
        try testing.expectEqual(allocations, failing.alloc_index);
        try testing.expectEqual(metadata, runtime.external_symbols.metadata);
        try testing.expectEqual(table_capacity, runtime.external_symbols.capacity());

        failing.fail_index = failing.alloc_index;
        try runtime.registerExternalSymbol("external_0", 99);
        try testing.expectEqual(@as(?usize, 99), runtime.external_symbols.get("external_0"));
        try testing.expectEqual(
            first_name,
            runtime.external_symbols.getEntry("external_0").?.key_ptr.*.ptr,
        );
        try testing.expectEqual(limits.external_symbols, runtime.external_symbols.count());
        try testing.expectEqual(allocations, failing.alloc_index);
        try testing.expectEqual(bytes, failing.allocated_bytes - failing.freed_bytes);
    }
}

test "JitRuntime failed external registration preserves storage and permits retry" {
    const testing = std.testing;
    for (0..2) |fail_offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var runtime = JitRuntime.init(failing.allocator(), .testing);
        defer runtime.deinit();
        try runtime.registerExternalSymbol("external_0", 1);
        const initial_entries = runtime.external_symbols.capacity() *
            std.hash_map.default_max_load_percentage / 100;
        var name: [32]u8 = undefined;
        for (1..initial_entries) |index| {
            const symbol = try std.fmt.bufPrint(&name, "external_{d}", .{index});
            try runtime.registerExternalSymbol(symbol, index + 1);
        }
        const bytes = failing.allocated_bytes - failing.freed_bytes;
        const metadata = runtime.external_symbols.metadata;
        const table_capacity = runtime.external_symbols.capacity();
        failing.fail_index = failing.alloc_index + fail_offset;
        try testing.expectError(
            error.OutOfMemory,
            runtime.registerExternalSymbol("next", initial_entries + 1),
        );
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(@as(u32, initial_entries), runtime.external_symbols.count());
        try testing.expect(!runtime.external_symbols.contains("next"));
        try testing.expectEqual(bytes, failing.allocated_bytes - failing.freed_bytes);
        try testing.expectEqual(metadata, runtime.external_symbols.metadata);
        try testing.expectEqual(table_capacity, runtime.external_symbols.capacity());
        for (0..initial_entries) |index| {
            const symbol = try std.fmt.bufPrint(&name, "external_{d}", .{index});
            try testing.expectEqual(@as(?usize, index + 1), runtime.external_symbols.get(symbol));
        }
        failing.fail_index = std.math.maxInt(usize);
        try runtime.registerExternalSymbol("next", initial_entries + 1);
        try testing.expectEqual(@as(u32, initial_entries + 1), runtime.external_symbols.count());
        try testing.expectEqual(
            @as(?usize, initial_entries + 1),
            runtime.external_symbols.get("next"),
        );
    }
}

test "JitRuntime zero external symbol limit refuses before allocating" {
    const testing = std.testing;
    var limits: JitRuntime.Limits = .testing;
    limits.external_symbols = 0;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var runtime = JitRuntime.init(failing.allocator(), limits);
    defer runtime.deinit();
    try testing.expectError(error.JitRuntimeFull, runtime.registerExternalSymbol("first", 1));
    try testing.expectEqual(@as(u32, 0), runtime.external_symbols.count());
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
}
