const std = @import("std");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ConjectureData = conjecture.ConjectureData;
const DrawError = conjecture.DrawError;
const engine_mod = @import("engine.zig");
const report_mod = @import("report.zig");
const Settings = engine_mod.Settings;

pub fn StateMachine(comptime Model: type) type {
    validateModel(Model);

    return struct {
        pub fn check(allocator: Allocator) !void {
            try checkWithSettings(allocator, .{});
        }

        pub fn checkWithSettings(allocator: Allocator, settings: Settings) !void {
            const Wrapper = struct {
                fn testFn(data: *ConjectureData, alloc: Allocator) anyerror!void {
                    try data.beginSpan("stateful");

                    var state = Model.initialState();
                    const sut = try Model.initSut(alloc);
                    defer Model.deinitSut(sut, alloc);

                    const max_commands: usize = 50;
                    for (0..max_commands) |_| {
                        const more = data.drawBoolean() catch break;
                        if (!more) break;

                        try data.beginSpan("command");

                        const cmd = Model.genCommand(state, data, alloc) catch break;

                        if (!Model.precondition(state, cmd)) {
                            data.endSpan();
                            continue;
                        }

                        const result = Model.runCommand(cmd, sut);

                        if (!Model.postcondition(state, cmd, result)) {
                            data.endSpan();
                            data.endSpan();
                            return error.PostconditionFailed;
                        }

                        state = Model.nextState(state, cmd);
                        data.endSpan();
                    }

                    data.endSpan();
                }
            };

            var result = try engine_mod.run(allocator, &Wrapper.testFn, settings);
            defer result.deinit();

            if (!result.passed) {
                if (settings.report_failure) {
                    report_mod.printStatefulFailure(&result);
                }
                return error.StatefulTestFailed;
            }
        }
    };
}

fn validateModel(comptime Model: type) void {
    const info = @typeInfo(Model);
    if (info != .@"struct") @compileError("StateMachine Model must be a struct");

    if (!@hasDecl(Model, "State")) @compileError("Model must declare 'State' type");
    if (!@hasDecl(Model, "Command")) @compileError("Model must declare 'Command' type");
    if (!@hasDecl(Model, "Sut")) @compileError("Model must declare 'Sut' type");

    if (!@hasDecl(Model, "initialState")) @compileError("Model must declare 'initialState()'");
    if (!@hasDecl(Model, "genCommand")) @compileError("Model must declare 'genCommand()'");
    if (!@hasDecl(Model, "precondition")) @compileError("Model must declare 'precondition()'");
    if (!@hasDecl(Model, "nextState")) @compileError("Model must declare 'nextState()'");
    if (!@hasDecl(Model, "postcondition")) @compileError("Model must declare 'postcondition()'");
    if (!@hasDecl(Model, "runCommand")) @compileError("Model must declare 'runCommand()'");
    if (!@hasDecl(Model, "initSut")) @compileError("Model must declare 'initSut()'");
    if (!@hasDecl(Model, "deinitSut")) @compileError("Model must declare 'deinitSut()'");
}

const StackModel = struct {
    pub const State = struct {
        size: usize = 0,
    };

    pub const Command = union(enum) {
        push: i32,
        pop,
    };

    pub const Sut = struct {
        items: std.ArrayListUnmanaged(i32) = .empty,
        allocator: Allocator,

        fn init(allocator: Allocator) Sut {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *Sut) void {
            self.items.deinit(self.allocator);
        }
    };

    pub fn initialState() State {
        return .{};
    }

    pub fn genCommand(state: State, data: *ConjectureData, _: Allocator) DrawError!Command {
        if (state.size == 0) {
            const val_raw = try data.drawInteger(0, 200, 100);
            const val: i32 = @intCast(val_raw);
            return .{ .push = val - 100 };
        }
        const choice = try data.drawBoolean();
        if (choice) {
            return .pop;
        } else {
            const val_raw = try data.drawInteger(0, 200, 100);
            const val: i32 = @intCast(val_raw);
            return .{ .push = val - 100 };
        }
    }

    pub fn precondition(state: State, cmd: Command) bool {
        return switch (cmd) {
            .pop => state.size > 0,
            .push => true,
        };
    }

    pub fn nextState(state: State, cmd: Command) State {
        return switch (cmd) {
            .push => .{ .size = state.size + 1 },
            .pop => .{ .size = state.size - 1 },
        };
    }

    pub fn postcondition(state: State, cmd: Command, _: void) bool {
        _ = state;
        _ = cmd;
        return true;
    }

    pub fn runCommand(cmd: Command, sut: *Sut) void {
        switch (cmd) {
            .push => |v| sut.items.append(sut.allocator, v) catch {},
            .pop => {
                _ = sut.items.pop();
            },
        }
    }

    pub fn initSut(allocator: Allocator) !*Sut {
        const sut = try allocator.create(Sut);
        sut.* = Sut.init(allocator);
        return sut;
    }

    pub fn deinitSut(sut: *Sut, allocator: Allocator) void {
        sut.deinit();
        allocator.destroy(sut);
    }
};

test "stateful: stack model" {
    const allocator = std.testing.allocator;
    try StateMachine(StackModel).check(allocator);
}

const BrokenDepthModel = struct {
    pub const State: type = StackModel.State;
    pub const Command: type = StackModel.Command;
    pub const Sut: type = StackModel.Sut;

    pub const initialState = StackModel.initialState;
    pub const genCommand = StackModel.genCommand;
    pub const precondition = StackModel.precondition;
    pub const nextState = StackModel.nextState;
    pub const runCommand = StackModel.runCommand;
    pub const initSut = StackModel.initSut;
    pub const deinitSut = StackModel.deinitSut;

    pub fn postcondition(state: State, cmd: Command, _: void) bool {
        return switch (cmd) {
            .push => state.size < 2,
            .pop => true,
        };
    }
};

test "stateful: failing postcondition shrinks without corrupting memory" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.StatefulTestFailed,
        StateMachine(BrokenDepthModel).checkWithSettings(allocator, .{
            .seed = 7,
            .report_failure = false,
        }),
    );
}
