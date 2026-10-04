const kernel_program = @import("../../program/root.zig");
const domain = @import("../domain/root.zig");

pub const Threads = struct {
    x: u32 = 256,
    y: u32 = 4,
    z: u32 = 1,
};

pub const ThreadBlocks = struct {
    threads: Threads,

    pub fn index1D(
        self: ThreadBlocks,
        owner: anytype,
        axis_value: domain.Axis,
    ) !kernel_program.Index1D {
        return owner.index1D(axis_value.name, axis_value.extent, self.threads.x);
    }

    pub fn index2D(
        self: ThreadBlocks,
        owner: anytype,
        shape: domain.Domain2D,
    ) !kernel_program.Index2D {
        return owner.index2D(.{
            .x = kernel_program.domainAxis(shape.x.name, shape.x.extent, self.threads.x),
            .y = kernel_program.domainAxis(shape.y.name, shape.y.extent, self.threads.y),
        });
    }

    pub fn index3D(
        self: ThreadBlocks,
        owner: anytype,
        shape: domain.Domain3D,
    ) !kernel_program.Index3D {
        return owner.index3D(.{
            .x = kernel_program.domainAxis(shape.x.name, shape.x.extent, self.threads.x),
            .y = kernel_program.domainAxis(shape.y.name, shape.y.extent, self.threads.y),
            .z = kernel_program.domainAxis(shape.z.name, shape.z.extent, self.threads.z),
        });
    }
};

pub const UseThreads = struct {
    threads: Threads,

    pub fn index1D(self: *@This(), ctx: anytype) !kernel_program.Index1D {
        return ctx.useThreads(self.threads.x);
    }

    pub fn index2D(self: *@This(), ctx: anytype) !kernel_program.Index2D {
        return ctx.useThreads(self.threads);
    }

    pub fn index3D(self: *@This(), ctx: anytype) !kernel_program.Index3D {
        return ctx.useThreads(self.threads);
    }
};

pub fn with(impl: anytype) With(@TypeOf(impl)) {
    return .{ .impl = impl };
}

pub fn useThreads(threads: Threads) With(UseThreads) {
    return with(UseThreads{ .threads = threads });
}

pub fn With(comptime Impl: type) type {
    return struct {
        impl: Impl,

        pub fn attach(self: @This(), next: anytype) Layer(@TypeOf(next), Impl) {
            return .{
                .next = next,
                .impl = self.impl,
            };
        }
    };
}

pub fn stack(specs: anytype) StackAttach(0, @TypeOf(specs), ThreadBlocks) {
    return attachFrom(0, specs, default());
}

pub fn Layer(comptime Next: type, comptime Impl: type) type {
    return struct {
        next: Next,
        impl: Impl,

        const Self = @This();

        pub fn index1D(
            self: *Self,
            owner: anytype,
            axis_value: domain.Axis,
        ) !kernel_program.Index1D {
            if (comptime @hasDecl(Impl, "index1D")) {
                var ctx = Index1DContext(PointerChild(@TypeOf(owner)), Next){
                    .owner = owner,
                    .next = &self.next,
                    .axis = axis_value,
                };
                return self.impl.index1D(&ctx);
            }
            return self.next.index1D(owner, axis_value);
        }

        pub fn index2D(
            self: *Self,
            owner: anytype,
            shape: domain.Domain2D,
        ) !kernel_program.Index2D {
            if (comptime @hasDecl(Impl, "index2D")) {
                var ctx = Index2DContext(PointerChild(@TypeOf(owner)), Next){
                    .owner = owner,
                    .next = &self.next,
                    .shape = shape,
                };
                return self.impl.index2D(&ctx);
            }
            return self.next.index2D(owner, shape);
        }

        pub fn index3D(
            self: *Self,
            owner: anytype,
            shape: domain.Domain3D,
        ) !kernel_program.Index3D {
            if (comptime @hasDecl(Impl, "index3D")) {
                var ctx = Index3DContext(PointerChild(@TypeOf(owner)), Next){
                    .owner = owner,
                    .next = &self.next,
                    .shape = shape,
                };
                return self.impl.index3D(&ctx);
            }
            return self.next.index3D(owner, shape);
        }
    };
}

pub fn Index1DContext(comptime Owner: type, comptime Next: type) type {
    return struct {
        owner: *Owner,
        next: *Next,
        axis: domain.Axis,

        pub fn default(self: *@This()) !kernel_program.Index1D {
            return self.next.index1D(self.owner, self.axis);
        }

        pub fn useThreads(self: *@This(), threads_per_block: u32) !kernel_program.Index1D {
            return self.owner.index1D(self.axis.name, self.axis.extent, threads_per_block);
        }
    };
}

pub fn Index2DContext(comptime Owner: type, comptime Next: type) type {
    return struct {
        owner: *Owner,
        next: *Next,
        shape: domain.Domain2D,

        pub fn default(self: *@This()) !kernel_program.Index2D {
            return self.next.index2D(self.owner, self.shape);
        }

        pub fn useThreads(self: *@This(), threads: Threads) !kernel_program.Index2D {
            return self.owner.index2D(.{
                .x = kernel_program.domainAxis(self.shape.x.name, self.shape.x.extent, threads.x),
                .y = kernel_program.domainAxis(self.shape.y.name, self.shape.y.extent, threads.y),
            });
        }
    };
}

pub fn Index3DContext(comptime Owner: type, comptime Next: type) type {
    return struct {
        owner: *Owner,
        next: *Next,
        shape: domain.Domain3D,

        pub fn default(self: *@This()) !kernel_program.Index3D {
            return self.next.index3D(self.owner, self.shape);
        }

        pub fn useThreads(self: *@This(), threads: Threads) !kernel_program.Index3D {
            return self.owner.index3D(.{
                .x = kernel_program.domainAxis(self.shape.x.name, self.shape.x.extent, threads.x),
                .y = kernel_program.domainAxis(self.shape.y.name, self.shape.y.extent, threads.y),
                .z = kernel_program.domainAxis(self.shape.z.name, self.shape.z.extent, threads.z),
            });
        }
    };
}

pub fn threadBlocks(threads: Threads) ThreadBlocks {
    return .{ .threads = threads };
}

pub fn default() ThreadBlocks {
    return threadBlocks(.{});
}

fn stackLength(comptime Specs: type) comptime_int {
    const info = @typeInfo(Specs);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("kernel.logical.schedule.stack expects a tuple of schedule layers");
    }
    if (info.@"struct".field_names.len == 0) {
        @compileError("kernel.logical.schedule.stack expects at least one schedule layer");
    }
    return info.@"struct".field_names.len;
}

fn StackAttach(comptime index: usize, comptime Specs: type, comptime Next: type) type {
    const len = stackLength(Specs);
    if (index == len) return Next;
    const Spec = @typeInfo(Specs).@"struct".field_types[index];
    return @TypeOf(
        @as(Spec, undefined).attach(@as(StackAttach(index + 1, Specs, Next), undefined)),
    );
}

fn attachFrom(
    comptime index: usize,
    specs: anytype,
    next: anytype,
) StackAttach(index, @TypeOf(specs), @TypeOf(next)) {
    if (comptime index == stackLength(@TypeOf(specs))) return next;
    const inner = attachFrom(index + 1, specs, next);
    return @field(specs, @typeInfo(@TypeOf(specs)).@"struct".field_names[index]).attach(inner);
}

fn PointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("logical schedules attach to builder pointers"),
    };
}
