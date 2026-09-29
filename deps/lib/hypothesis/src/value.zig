const std = @import("std");
const engine = @import("engine.zig");
const conjecture = @import("conjecture.zig");
const strategy = @import("strategy.zig");

const ConjectureData = conjecture.ConjectureData;

pub const Config = struct {
    max_examples: u32 = 100,
    max_replays: u32 = 100,
    max_shrinks: u32 = 1000,
    max_choices: usize = 8192,
    max_input_bytes: usize = conjecture.default_max_input_bytes,
    seed: ?u64 = null,
    persist_failures: bool = true,
    report_failures: bool = true,
    test_name: ?[]const u8 = null,

    pub fn quick() Config {
        return .{
            .max_examples = 10,
            .max_replays = 10,
            .max_shrinks = 100,
            .max_choices = 4096,
            .max_input_bytes = 256 * 1024,
        };
    }

    pub fn dev() Config {
        return .{};
    }

    pub fn ci() Config {
        return .{
            .max_examples = 1000,
            .max_replays = 1000,
            .max_shrinks = 5000,
            .max_input_bytes = 4 * 1024 * 1024,
        };
    }

    pub fn expectedSlow(max_examples: u32, _: u64) Config {
        return .{ .max_examples = max_examples, .max_replays = max_examples };
    }

    pub fn toSettings(self: Config) engine.Settings {
        return .{
            .max_examples = @intCast(self.max_examples),
            .max_replays = @intCast(self.max_replays),
            .max_choices = self.max_choices,
            .max_input_bytes = self.max_input_bytes,
            .max_shrinks = @intCast(self.max_shrinks),
            .seed = self.seed,
            .database_path = if (self.persist_failures) "zig-out/pbt-failures" else null,
            .database_namespace = self.test_name,
            .report_failure = self.report_failures,
        };
    }
};

pub fn Generator(comptime T: type) type {
    return struct {
        drawFn: *const fn (*ConjectureData) anyerror!T,

        const Self = @This();

        pub fn draw(self: Self, data: *ConjectureData) anyerror!T {
            return self.drawFn(data);
        }

        pub fn map(
            comptime self: Self,
            comptime U: type,
            comptime f: *const fn (T) U,
        ) Generator(U) {
            return .{ .drawFn = &MappedGeneratorType(T, U, self, f).draw };
        }

        pub fn filter(comptime self: Self, comptime pred: *const fn (T) bool) Self {
            return .{ .drawFn = &FilteredGeneratorType(T, self, pred).draw };
        }

        pub fn flatMap(
            comptime self: Self,
            comptime U: type,
            comptime f: *const fn (T) Generator(U),
        ) Generator(U) {
            return .{ .drawFn = &FlatMappedGeneratorType(T, U, self, f).draw };
        }
    };
}

fn MappedGeneratorType(
    comptime T: type,
    comptime U: type,
    comptime source: Generator(T),
    comptime transform: *const fn (T) U,
) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!U {
            return transform(try source.drawFn(data));
        }
    };
}

fn FilteredGeneratorType(
    comptime T: type,
    comptime source: Generator(T),
    comptime predicate: *const fn (T) bool,
) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!T {
            for (0..10) |_| {
                const value = try source.drawFn(data);
                if (predicate(value)) return value;
            }
            data.markInvalid();
            return error.Rejected;
        }
    };
}

fn FlatMappedGeneratorType(
    comptime T: type,
    comptime U: type,
    comptime source: Generator(T),
    comptime transform: *const fn (T) Generator(U),
) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!U {
            const value = try source.drawFn(data);
            return transform(value).drawFn(data);
        }
    };
}

fn IntegerGeneratorType(
    comptime T: type,
    comptime min_value: T,
    comptime max_value: T,
) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!T {
            const shrink_towards: T = if (min_value <= 0 and 0 <= max_value)
                0
            else
                min_value;
            const raw = try data.drawInteger(
                strategy.intToU64(T, min_value),
                strategy.intToU64(T, max_value),
                strategy.intToU64(T, shrink_towards),
            );
            return strategy.u64ToInt(T, raw);
        }
    };
}

pub fn integer(comptime T: type, comptime min_val: T, comptime max_val: T) Generator(T) {
    comptime {
        const info = @typeInfo(T);
        if (info != .int) @compileError("integer generator requires an integer type");
        if (min_val > max_val) @compileError("min must be <= max");
    }

    return .{ .drawFn = &IntegerGeneratorType(T, min_val, max_val).draw };
}

fn Float32GeneratorType(comptime min_value: f32, comptime max_value: f32) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!f32 {
            return @floatCast(try data.drawFloat(min_value, max_value));
        }
    };
}

pub fn float32(comptime min_val: f32, comptime max_val: f32) Generator(f32) {
    return .{ .drawFn = &Float32GeneratorType(min_val, max_val).draw };
}

fn Float64GeneratorType(comptime min_value: f64, comptime max_value: f64) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!f64 {
            return try data.drawFloat(min_value, max_value);
        }
    };
}

pub fn float64(comptime min_val: f64, comptime max_val: f64) Generator(f64) {
    return .{ .drawFn = &Float64GeneratorType(min_val, max_val).draw };
}

fn draw_boolean(data: *ConjectureData) anyerror!bool {
    return try data.drawBoolean();
}

pub fn boolean() Generator(bool) {
    return .{ .drawFn = &draw_boolean };
}

fn BytesGeneratorType(comptime max_len: usize) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror![]const u8 {
            return try data.drawBytes(0, max_len);
        }
    };
}

pub fn bytes(comptime max_len: usize) Generator([]const u8) {
    return .{ .drawFn = &BytesGeneratorType(max_len).draw };
}

pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const T {
            return self.buf[0..self.len];
        }
    };
}

fn ListGeneratorType(
    comptime T: type,
    comptime inner: Generator(T),
    comptime max_len: usize,
) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!BoundedArray(T, max_len) {
            var result: BoundedArray(T, max_len) = .{};
            for (0..max_len) |_| {
                if (!try data.drawBoolean()) break;
                result.buf[result.len] = try inner.drawFn(data);
                result.len += 1;
            }
            return result;
        }
    };
}

pub fn list(
    comptime T: type,
    comptime inner: Generator(T),
    comptime max_len: usize,
) Generator(BoundedArray(T, max_len)) {
    return .{ .drawFn = &ListGeneratorType(T, inner, max_len).draw };
}

fn FixedArrayGeneratorType(
    comptime T: type,
    comptime inner: Generator(T),
    comptime length: usize,
) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror![length]T {
            var result: [length]T = undefined;
            for (&result) |*slot| slot.* = try inner.drawFn(data);
            return result;
        }
    };
}

pub fn fixedArray(
    comptime T: type,
    comptime inner: Generator(T),
    comptime N: usize,
) Generator([N]T) {
    return .{ .drawFn = &FixedArrayGeneratorType(T, inner, N).draw };
}

fn GenPayload(comptime G: type) type {
    const draw_fn_ptr = @typeInfo(G).@"struct".field_types[0];
    const draw_fn = @typeInfo(draw_fn_ptr).pointer.child;
    const ret = @typeInfo(draw_fn).@"fn".return_type.?;
    return @typeInfo(ret).error_union.payload;
}

fn TupleResult(comptime gens: anytype) type {
    var fields: [gens.len]type = undefined;
    inline for (0..gens.len) |i| {
        fields[i] = GenPayload(@TypeOf(gens[i]));
    }
    return @Tuple(&fields);
}

fn TupleGeneratorType(comptime generators: anytype) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!TupleResult(generators) {
            var result: TupleResult(generators) = undefined;
            inline for (0..generators.len) |index| {
                result[index] = try generators[index].drawFn(data);
            }
            return result;
        }
    };
}

pub fn tuple(comptime gens: anytype) Generator(TupleResult(gens)) {
    return .{ .drawFn = &TupleGeneratorType(gens).draw };
}

fn OneOfGeneratorType(comptime T: type, comptime generators: anytype) type {
    return struct {
        fn draw(data: *ConjectureData) anyerror!T {
            const index = try data.drawInteger(0, generators.len - 1, 0);
            inline for (0..generators.len) |generator_index| {
                if (index == generator_index) {
                    return generators[generator_index].drawFn(data);
                }
            }
            unreachable;
        }
    };
}

pub fn oneOf(comptime T: type, comptime gens: anytype) Generator(T) {
    const n = gens.len;
    if (n == 0) @compileError("oneOf requires at least one generator");
    return .{ .drawFn = &OneOfGeneratorType(T, gens).draw };
}

pub fn gen_point(comptime min: f32, comptime max: f32) Generator([3]f32) {
    return comptime fixedArray(f32, float32(min, max), 3);
}

fn is_nonzero_vec3(value: [3]f32) bool {
    return value[0] * value[0] + value[1] * value[1] + value[2] * value[2] > 0.01;
}

fn normalize_vec3(value: [3]f32) [3]f32 {
    const norm = @sqrt(
        value[0] * value[0] +
            value[1] * value[1] +
            value[2] * value[2],
    );
    return .{ value[0] / norm, value[1] / norm, value[2] / norm };
}

pub fn gen_unit_vec3() Generator([3]f32) {
    return comptime gen_point(-1.0, 1.0)
        .filter(&is_nonzero_vec3)
        .map([3]f32, &normalize_vec3);
}

fn is_nonzero_quaternion(value: [4]f32) bool {
    return value[0] * value[0] +
        value[1] * value[1] +
        value[2] * value[2] +
        value[3] * value[3] > 0.01;
}

fn normalize_quaternion(value: [4]f32) [4]f32 {
    const norm = @sqrt(
        value[0] * value[0] +
            value[1] * value[1] +
            value[2] * value[2] +
            value[3] * value[3],
    );
    return .{
        value[0] / norm,
        value[1] / norm,
        value[2] / norm,
        value[3] / norm,
    };
}

pub fn gen_quaternion() Generator([4]f32) {
    return comptime fixedArray(f32, float32(-1.0, 1.0), 4)
        .filter(&is_nonzero_quaternion)
        .map([4]f32, &normalize_quaternion);
}

fn CheckValuePropertyType(
    comptime T: type,
    comptime generator: Generator(T),
    comptime property: *const fn (T) anyerror!void,
) type {
    return struct {
        fn run(data: *ConjectureData, _: std.mem.Allocator) anyerror!void {
            const value = generator.draw(data) catch |err| switch (err) {
                error.Overrun => return,
                error.Rejected => {
                    data.markInvalid();
                    return;
                },
                else => return err,
            };
            if (data.status != .valid) return;
            try property(value);
        }
    };
}

fn CheckValueAllocPropertyType(
    comptime T: type,
    comptime generator: Generator(T),
    comptime property: *const fn (std.mem.Allocator, T) anyerror!void,
) type {
    return struct {
        fn run(
            data: *ConjectureData,
            property_allocator: std.mem.Allocator,
        ) anyerror!void {
            const value = generator.draw(data) catch |err| switch (err) {
                error.Overrun => return,
                error.Rejected => {
                    data.markInvalid();
                    return;
                },
                else => return err,
            };
            if (data.status != .valid) return;
            try property(property_allocator, value);
        }
    };
}

pub fn checkValue(
    comptime T: type,
    comptime gen: Generator(T),
    comptime property: *const fn (T) anyerror!void,
    config: Config,
    allocator: std.mem.Allocator,
) !void {
    const Property = CheckValuePropertyType(T, gen, property);

    var settings = config.toSettings();
    if (settings.database_namespace == null) {
        settings.database_namespace = @typeName(Property);
    }

    var result = try engine.run(allocator, &Property.run, settings);
    defer result.deinit();

    if (!result.passed) {
        if (settings.report_failure) @import("testing.zig").printFailure(&result);
        return result.failing_error orelse error.PropertyFailed;
    }
}

pub fn checkValueAlloc(
    comptime T: type,
    comptime gen: Generator(T),
    comptime property: *const fn (std.mem.Allocator, T) anyerror!void,
    config: Config,
    allocator: std.mem.Allocator,
) !void {
    const Property = CheckValueAllocPropertyType(T, gen, property);

    var settings = config.toSettings();
    if (settings.database_namespace == null) {
        settings.database_namespace = @typeName(Property);
    }

    var result = try engine.run(allocator, &Property.run, settings);
    defer result.deinit();

    if (!result.passed) {
        if (settings.report_failure) @import("testing.zig").printFailure(&result);
        return result.failing_error orelse error.PropertyFailed;
    }
}
