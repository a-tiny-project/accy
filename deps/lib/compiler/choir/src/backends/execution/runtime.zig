//! Executable modules addressed by generation-checked handles, over one target.

const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const debug_info = backends.debug_info;
const machine = backends.machine_code;
const sys = @import("sys");
const image = @import("image.zig");
const load = @import("load.zig");
const target = @import("target.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;
const Signature = artifact.Signature;
const Handle = image.Handle;
const Module = image.Module;
const FunctionEntry = image.FunctionEntry;
const Limits = @import("limits.zig").Limits;

pub const UnavailableError = error{ExecutionUnavailable};
pub const CapacityError = error{JitRuntimeFull};
pub const HandleError = error{InvalidModuleHandle};
pub const LookupError = HandleError || error{FunctionNotFound};
pub const CallError = LookupError || error{SignatureMismatch};
pub const SymbolError = Allocator.Error || CapacityError;
pub const InitError = SymbolError || UnavailableError || error{UnsupportedPublicationPolicy};
pub const MapError = sys.memory.PublicationError;
pub const LoadError = Allocator.Error || MapError || CapacityError ||
    error{ InvalidArtifact, SymbolNotFound };
/// Lowering errors keep their meaning. `JitCompileFailed` is an emission failure and
/// `SymbolNotFound` a call no definition resolves; each reports one located diagnostic.
pub const CompileError = Allocator.Error || MapError || CapacityError || target.LowerError ||
    error{ JitCompileFailed, SymbolNotFound };
const LinkError = Allocator.Error || MapError || CapacityError ||
    error{ DataTooLarge, SymbolNotFound };

/// Which limit refused, and by how much.
pub const Refusal = struct {
    limit: Limit,
    /// The limit as the runtime was built with it.
    bound: u64,
    /// What live modules or registered names held when the request came.
    in_use: u64,
    /// What the refused request asked for.
    requested: u64,

    pub const Limit = enum { live_modules, mapped_bytes, external_symbols };
};

/// A function of a `Target` module: its address and the signature it recorded.
fn Resolved(comptime Target: type) type {
    return struct {
        address: usize,
        signature: Signature,

        const Entry = @This();

        /// Calls the function with `args` and stores its results in `results`. Fails with
        /// `error.SignatureMismatch`, without calling, when an argument's type, the argument
        /// count, or the number of result slots differs from the recorded signature.
        pub fn call(
            self: *const Entry,
            args: []const value.Value,
            results: []value.Value,
        ) error{SignatureMismatch}!void {
            try value.check(&self.signature, args, results);
            Target.enter(self.address, &self.signature, args, results);
        }
    };
}

/// Executable modules for `Target`, which `target.assertTarget` checks.
/// Each module owns its code and data until `release`. Compiling or loading another module never
/// moves or frees them.
pub fn Runtime(comptime Target: type) type {
    comptime target.assertTarget(Target);
    return struct {
        allocator: Allocator,
        limits: Limits,
        executable_policy: sys.memory.ExecutablePolicy,
        live_modules: u32,
        /// The bytes live modules hold mapped, as the kernel reserved them. The running total
        /// moves alongside `live_modules`, at `install` and `release`. A compile that fails partway
        /// spends none of the budget, because the module never reaches `install` and its
        /// `errdefer` unmaps whatever it had mapped.
        mapped_bytes: u64,
        modules: std.ArrayListUnmanaged(Module),
        external_symbols: std.StringHashMapUnmanaged(usize),
        compiler: Target.Compiler,
        /// The most recent refusal with `error.JitRuntimeFull`, or null when there was none.
        refusal: ?Refusal,
        /// Functions whose code outgrew the bytes the target reserved for it, since `init`.
        /// The reservation rests on a measured ratio, so a host can check it held.
        code_fallbacks: u64,

        const Self = @This();
        const View: type = load.View(Target);

        /// The policy ordinary `init` uses. Apple has no implied product declaration.
        pub const default_executable_policy: sys.memory.ExecutablePolicy = if (Target.executable_policy == .linux)
            .linux
        else
            .unverified;

        /// Whether ordinary `init` can build a runtime. A qualified Apple caller can still
        /// use `initWithExecutablePolicy` after making its explicit product declaration.
        pub const available = Target.unavailable == null and default_executable_policy != .unverified;

        const Entry: type = Resolved(Target);

        /// Builds a runtime using Linux's established publication policy. The Apple default is
        /// unverified and refuses before allocation: callers of a qualified startup-linked,
        /// non-hardened product must declare that policy with `initWithExecutablePolicy`.
        pub fn init(allocator: Allocator, limits: Limits) InitError!Self {
            return initWithExecutablePolicy(allocator, limits, default_executable_policy);
        }

        /// Builds a runtime bounded by `limits` and binds the target's built-in names, which
        /// count against `limits.external_symbols`. Fails with `error.ExecutionUnavailable`
        /// before allocating when this host has no target, and with `error.JitRuntimeFull` when
        /// the limit cannot hold the built-ins. `policy` is the caller's product declaration,
        /// checked against the target contract before any allocation or executable mapping.
        pub fn initWithExecutablePolicy(
            allocator: Allocator,
            limits: Limits,
            policy: sys.memory.ExecutablePolicy,
        ) InitError!Self {
            if (Target.unavailable != null) return error.ExecutionUnavailable;
            if (policy == .unverified or policy != Target.executable_policy)
                return error.UnsupportedPublicationPolicy;
            try sys.memory.validateExecutablePolicy(policy);
            std.debug.assert(limits.live_modules != 0);
            std.debug.assert(limits.mapped_bytes != 0);
            var self: Self = .{
                .allocator = allocator,
                .limits = limits,
                .executable_policy = policy,
                .live_modules = 0,
                .mapped_bytes = 0,
                .modules = .empty,
                .external_symbols = .empty,
                .compiler = Target.initCompiler(allocator),
                .refusal = null,
                .code_fallbacks = 0,
            };
            errdefer self.deinit();
            Target.recordLines(&self.compiler, limits.line_tables);
            for (0..Target.builtin_count) |index| {
                const builtin = Target.builtin(index);
                try self.registerExternalSymbol(builtin.name, builtin.address);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.modules.items) |*module| {
                if (module.live) module.unload(self.allocator);
            }
            self.modules.deinit(self.allocator);

            var names = self.external_symbols.keyIterator();
            while (names.next()) |name| self.allocator.free(name.*);
            self.external_symbols.deinit(self.allocator);

            Target.deinitCompiler(&self.compiler);
            self.* = undefined;
        }

        /// Lowers `module` and compiles every function definition in it into a new module.
        /// Loads what lowering needs into `module`'s context first. Keeps nothing that points into
        /// the context, so the returned module stays callable after the context is gone.
        ///
        /// Lowering refuses with its own error and diagnostic before anything is emitted.
        /// Calls resolve against the module's own functions first, then registered external
        /// symbols, and data symbols against the module's own data.
        /// Fails with `error.JitCompileFailed` when a function fails to emit, reporting one error
        /// diagnostic at the innermost operation whose emission failed, or else at the function.
        /// Fails with `error.SymbolNotFound` when nothing defines a call's target, reporting one
        /// error diagnostic at the first `func.call` naming it, or else at the calling function.
        /// Fails with `error.OutOfMemory`, reporting nothing, when an allocation fails.
        /// Fails with `error.JitRuntimeFull`, reporting nothing and recording `refusal`, when the
        /// runtime already holds `limits.live_modules` modules or when this module's pages would
        /// carry it past `limits.mapped_bytes`. A `release` admits the next module.
        /// A failed compile leaves every existing module callable and spends none of either budget.
        pub fn compile(self: *Self, module: *ir.Operation) CompileError!Handle {
            try Target.prepare(module.getContext());
            try Target.lower(self.allocator, module);
            const region = module.getRegion(0) orelse return error.JitCompileFailed;
            const block = region.getEntryBlock() orelse return error.JitCompileFailed;
            const index = try self.reserveModule();

            var staged: Module = .staged;
            errdefer staged.unload(self.allocator);
            var builder: image.ImageBuilder = .{};
            defer builder.deinit(self.allocator);

            var op_iter = block.operations.head;
            while (op_iter) |op_ptr| {
                const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                op_iter = op.next_op;
                if (!std.mem.eql(u8, op.name.name, dialects.FuncDialect.FuncOp.operation_name)) continue;
                if (op.getRegion(0) == null) continue;
                self.emitFunction(&staged, &builder, op) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.JitCompileFailed,
                };
            }
            if (builder.code.items.len != 0) {
                try self.resolveCalls(module, &staged, builder.calls.items);
                self.link(&staged, builder.image()) catch |err| switch (err) {
                    error.DataTooLarge => return error.JitCompileFailed,
                    else => |narrow| return narrow,
                };
            }
            return self.install(index, staged);
        }

        /// Emits one function into the module image. Relocations stay unpatched until `link`.
        fn emitFunction(
            self: *Self,
            staged: *Module,
            builder: *image.ImageBuilder,
            func: *ir.Operation,
        ) !void {
            defer Target.discard(&self.compiler);
            self.stageFunction(staged, builder, func) catch |err| {
                Target.report(.{
                    .stage = .emit,
                    .operation = Target.failedOperation(&self.compiler) orelse func,
                    .err = err,
                });
                return err;
            };
        }

        fn stageFunction(
            self: *Self,
            staged: *Module,
            builder: *image.ImageBuilder,
            func: *ir.Operation,
        ) !void {
            const name = ir.SymbolTable.getSymbolName(func) orelse return error.NoFunctionName;
            if (staged.functions.contains(name)) return error.DuplicateSymbol;
            const signature = try backends.signature.ofFunction(func);
            if (!Target.admitsSignature(&signature)) return error.UnsupportedType;

            const emitted = try Target.emit(&self.compiler, func);
            if (emitted.code.len == 0) return error.EmptyFunction;
            if (emitted.outgrew_reservation) self.code_fallbacks += 1;
            const offset = try builder.append(self.allocator, emitted, try Target.takeCode(&self.compiler));

            try staged.functions.ensureUnusedCapacity(self.allocator, 1);
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            var entry = FunctionEntry{ .offset = offset, .size = emitted.code.len, .signature = signature };
            errdefer entry.deinit(self.allocator);
            if (self.limits.line_tables) entry.line_table = try Target.takeLineTable(&self.compiler);
            staged.functions.putAssumeCapacityNoClobber(owned_name, entry);
        }

        fn resolveCalls(
            self: *const Self,
            module: *ir.Operation,
            staged: *const Module,
            calls: []const machine.CallRelocation,
        ) error{SymbolNotFound}!void {
            for (calls) |call_site| {
                if (staged.functions.contains(call_site.target)) continue;
                if (self.externalAddress(call_site.target) != null) continue;
                Target.report(.{
                    .stage = .link,
                    .operation = callerOf(module, staged, call_site),
                    .err = error.SymbolNotFound,
                    .symbol = call_site.target,
                });
                return error.SymbolNotFound;
            }
        }

        /// Maps and seals data, then publishes code with resolved relocations.
        ///
        /// A module's data is one mapping, so one writable global leaves the whole mapping
        /// writable, read only symbols included. An object file places each section on its own
        /// and carries no such weakening.
        fn link(
            self: *Self,
            staged: *Module,
            staging: image.Image,
        ) LinkError!void {
            std.debug.assert(staged.code == null);
            std.debug.assert(staged.data == null);
            std.debug.assert(staging.code.len != 0);
            const symbols = staging.data.items();
            var layout = machine.DataLayout.init(self.allocator, symbols) catch |err| switch (err) {
                error.InvalidDataSymbol => unreachable,
                else => |narrow| return narrow,
            };
            defer layout.deinit(self.allocator);
            try self.admitMapping(image.mappedSize(staging.code.len) +| image.mappedSize(layout.size));

            const writable: sys.memory.Protection = .{ .read = true, .write = true };
            if (layout.size != 0) {
                const data = try sys.memory.mapAnonymous(layout.size, writable);
                std.debug.assert(data.len == image.mappedSize(layout.size));
                staged.data = data;
                layout.write(symbols, data);
                if (!anyWritable(symbols)) try sys.memory.protect(data, .{ .read = true });
            }

            staged.code = try sys.memory.ExecutableMapping.init(staging.code.len, self.executable_policy);
            std.debug.assert(staged.code.?.mappedBytes() == image.mappedSize(staging.code.len));
            const patch_count = std.math.add(usize, staging.calls.len, staging.data_relocations.len) catch
                return error.OutOfMemory;
            const patches = try self.allocator.alloc(sys.memory.ExecutablePatch, patch_count);
            defer self.allocator.free(patches);
            var patch_index: usize = 0;
            for (staging.calls) |call_site| {
                const address = if (staged.functions.getPtr(call_site.target)) |callee|
                    staged.reservationFunctionAddress(callee)
                else
                    self.externalAddress(call_site.target) orelse return error.SymbolNotFound;
                patches[patch_index] = resolvedPatch(Target, call_site.offset, address);
                patch_index += 1;
            }
            for (staging.data_relocations) |relocation| {
                std.debug.assert(relocation.width_bits == Target.relocation_bytes * 8);
                const symbol = staging.data.indexOf(relocation.target).?;
                const base: u64 = @intFromPtr(staged.data.?.ptr) + layout.offsets[symbol];
                const addend: u64 = @bitCast(relocation.addend);
                patches[patch_index] = resolvedPatch(Target, relocation.offset, base +% addend);
                patch_index += 1;
            }
            try staged.code.?.publish(staging.code, patches);
        }

        fn resolvedPatch(comptime PatchTarget: type, offset: usize, address: u64) sys.memory.ExecutablePatch {
            var bytes: [8]u8 = @splat(0);
            PatchTarget.patch(bytes[0..], 0, address);
            return .{ .offset = offset, .bytes = bytes, .len = @intCast(PatchTarget.relocation_bytes) };
        }

        /// Reports whether any symbol asks for storage the code may write.
        fn anyWritable(symbols: []const machine.DataSymbol) bool {
            for (symbols) |symbol| {
                if (symbol.section != .rodata) return true;
            }
            return false;
        }

        /// Reserves a slot so that installing a finished module cannot fail.
        fn reserveModule(self: *Self) (Allocator.Error || CapacityError)!u32 {
            std.debug.assert(self.live_modules <= self.limits.live_modules);
            if (self.live_modules >= self.limits.live_modules) {
                return self.refuse(.live_modules, self.limits.live_modules, self.live_modules, 1);
            }
            for (self.modules.items, 0..) |*module, index| {
                if (module.live) continue;
                if (module.generation == std.math.maxInt(u32)) continue;
                return @intCast(index);
            }
            const index = std.math.cast(u32, self.modules.items.len) orelse
                return self.refuse(.live_modules, self.limits.live_modules, self.live_modules, 1);
            try self.modules.ensureUnusedCapacity(self.allocator, 1);
            return index;
        }

        /// Refuses `charge` bytes before the runtime maps code or data. `reserveModule` checks
        /// the slot count at the top of a compile, but a module's size is not known until its
        /// code is emitted, so `link` checks the byte budget instead. Both checks answer the same
        /// capacity question and fail with `error.JitRuntimeFull`.
        ///
        /// The sum saturates rather than the budget being subtracted from, so a runtime already
        /// over its budget refuses instead of wrapping. A host reaches that state by lowering
        /// `limits.mapped_bytes` under what is already live, and the slot count answers the same
        /// move the same way.
        fn admitMapping(self: *Self, charge: u64) CapacityError!void {
            if (self.mapped_bytes +| charge > self.limits.mapped_bytes) {
                const bound = self.limits.mapped_bytes;
                return self.refuse(.mapped_bytes, bound, self.mapped_bytes, charge);
            }
        }

        fn refuse(
            self: *Self,
            limit: Refusal.Limit,
            bound: u64,
            in_use: u64,
            requested: u64,
        ) CapacityError {
            self.refusal = .{
                .limit = limit,
                .bound = bound,
                .in_use = in_use,
                .requested = requested,
            };
            return error.JitRuntimeFull;
        }

        fn install(self: *Self, index: u32, staged: Module) Handle {
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

        /// Unmaps the module's code and data. Function pointers and data addresses taken from it
        /// dangle afterward.
        pub fn release(self: *Self, handle: Handle) HandleError!void {
            const module = try self.liveModule(handle);
            const credit = module.mappedBytes();
            module.unload(self.allocator);
            std.debug.assert(self.live_modules != 0);
            self.live_modules -= 1;
            std.debug.assert(self.mapped_bytes >= credit);
            self.mapped_bytes -= credit;
        }

        fn liveModule(self: *const Self, handle: Handle) HandleError!*Module {
            if (handle.index >= self.modules.items.len) return error.InvalidModuleHandle;
            const module = &self.modules.items[handle.index];
            if (!module.live) return error.InvalidModuleHandle;
            if (module.generation != handle.generation) return error.InvalidModuleHandle;
            return module;
        }

        fn findFunction(self: *const Self, handle: Handle, name: []const u8) LookupError!Entry {
            const module = try self.liveModule(handle);
            const entry = module.functions.getPtr(name) orelse return error.FunctionNotFound;
            return .{ .address = module.functionAddress(entry), .signature = entry.signature };
        }

        /// Returns the address of `name` without checking how a caller will call it.
        /// Fails with `error.InvalidModuleHandle` when `handle` no longer resolves, and with
        /// `error.FunctionNotFound` when its module has no function `name`.
        pub fn functionAddress(
            self: *const Self,
            handle: Handle,
            name: []const u8,
        ) LookupError!usize {
            const found = try self.findFunction(handle, name);
            return found.address;
        }

        /// Returns the parameter and result types recorded for `name`.
        /// Fails with `error.InvalidModuleHandle` when `handle` no longer resolves, and with
        /// `error.FunctionNotFound` when its module has no function `name`.
        pub fn functionSignature(
            self: *const Self,
            handle: Handle,
            name: []const u8,
        ) LookupError!Signature {
            const found = try self.findFunction(handle, name);
            return found.signature;
        }

        /// Returns `name` as `FunctionPointer` when the signature derived from that type equals
        /// the recorded one. `backends.signature.ofZigFunction` gives the type mapping. Calls
        /// through the pointer are direct.
        /// Fails with `error.InvalidModuleHandle` or `error.FunctionNotFound` when the lookup
        /// fails, and with `error.SignatureMismatch` when the signatures differ.
        pub fn getFunction(
            self: *const Self,
            handle: Handle,
            name: []const u8,
            comptime FunctionPointer: type,
        ) CallError!FunctionPointer {
            const expected = backends.signature.ofZigFunction(FunctionPointer);
            const found = try self.findFunction(handle, name);
            if (!found.signature.eql(&expected)) return error.SignatureMismatch;
            return @ptrFromInt(found.address);
        }

        /// Calls `name` with `args` and stores its results in `results`, checking both against
        /// the recorded signature on every call.
        /// Fails with `error.InvalidModuleHandle` or `error.FunctionNotFound` when the lookup
        /// fails, and with `error.SignatureMismatch`, without calling, when an argument's type,
        /// the argument count, or the number of result slots differs from the recorded signature.
        pub fn call(
            self: *const Self,
            handle: Handle,
            name: []const u8,
            args: []const value.Value,
            results: []value.Value,
        ) CallError!void {
            const found = try self.findFunction(handle, name);
            try found.call(args, results);
        }

        /// Binds `name` for modules compiled or loaded afterward. Linked modules keep their
        /// targets. Replacing a name keeps its entry and owned name. A new name past
        /// `limits.external_symbols` fails with `error.JitRuntimeFull` before allocating and
        /// records `refusal`. Either refusal or allocation failure leaves the table, its retained
        /// storage, and all existing bindings unchanged.
        pub fn registerExternalSymbol(
            self: *Self,
            name: []const u8,
            address: usize,
        ) SymbolError!void {
            if (self.external_symbols.getPtr(name)) |existing| {
                existing.* = address;
                return;
            }

            const count = self.external_symbols.count();
            if (count >= self.limits.external_symbols) {
                return self.refuse(.external_symbols, self.limits.external_symbols, count, 1);
            }
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            try self.external_symbols.putNoClobber(self.allocator, owned_name, address);
            std.debug.assert(self.external_symbols.count() == count + 1);
            std.debug.assert(self.external_symbols.count() <= self.limits.external_symbols);
        }

        fn externalAddress(self: *const Self, name: []const u8) ?usize {
            const address = self.external_symbols.get(name) orelse return null;
            if (address == 0) return null;
            return address;
        }

        /// Loads one machine-code function and its data buffers into a new module.
        /// Call relocations resolve against the function itself, then registered external
        /// symbols. Absolute relocations resolve against the artifact's data buffers.
        /// Fails with `error.InvalidArtifact` before mapping anything when the artifact is
        /// malformed, is not machine code for this target, or its function symbol lacks a
        /// signature the target passes and returns.
        /// Fails with `error.SymbolNotFound` when a call relocation names neither the function
        /// nor a registered external symbol.
        /// Fails with `error.JitRuntimeFull` when the runtime already holds `limits.live_modules`
        /// modules or when this artifact's pages would carry it past `limits.mapped_bytes`.
        /// A failed load leaves every existing module callable and spends none of either budget.
        pub fn loadArtifact(self: *Self, serialized: *const artifact.Artifact) LoadError!Handle {
            var view = try View.init(self.allocator, serialized);
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
        pub fn writeDebugMap(self: *Self, writer: anytype) !bool {
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

        fn hasFunctions(self: *const Self) bool {
            for (self.modules.items) |*module| {
                if (!module.live) continue;
                if (module.functions.count() != 0) return true;
            }
            return false;
        }

        fn ensureDebugInfo(self: *Self, writer: anytype) void {
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
                    const address = module.functionAddress(function);
                    const code: []const u8 = @as([*]const u8, @ptrFromInt(address))[0..function.size];
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
}

/// The operation a failed call resolution is reported at: the first `func.call` naming the
/// target, or else the function whose code holds the call site.
fn callerOf(
    module: *ir.Operation,
    staged: *const Module,
    call_site: machine.CallRelocation,
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
