const std = @import("std");

pub fn Bins(comptime capacity: usize) type {
    return TypedBins(capacity, u32);
}

pub fn TypedBins(comptime capacity: usize, comptime Count: type) type {
    comptime requireBins(capacity, Count);

    return struct {
        counts: [capacity]Count = @splat(0),

        const Self = @This();
        pub const bin_count = capacity;
        pub const CountType = Count;

        pub fn notify(self: *Self, bin_value: anytype) void {
            const bin_index = index(bin_value);
            self.counts[bin_index] +%= 1;
        }

        pub fn incrementBy(self: *Self, bin_value: anytype, count: u32) void {
            const bin_index = index(bin_value);
            self.counts[bin_index] +%= countValue(count);
        }

        pub fn bin(self: *const Self, bin_index: usize) Count {
            std.debug.assert(bin_index < capacity);
            return self.counts[bin_index];
        }

        pub fn resetBin(self: *Self, bin_index: usize) void {
            std.debug.assert(bin_index < capacity);
            self.counts[bin_index] = 0;
        }

        pub fn assimilate(self: *Self, other: *const Self) void {
            for (&self.counts, other.counts) |*count, other_count| {
                count.* +%= other_count;
            }
        }

        pub fn firstNonzero(self: *const Self) usize {
            for (self.counts, 0..) |count, bin_index| {
                if (count != 0) return bin_index;
            }
            return capacity;
        }

        pub fn lastNonzero(self: *const Self) usize {
            var bin_index = capacity;
            while (bin_index != 0) {
                bin_index -= 1;
                if (self.counts[bin_index] != 0) return bin_index;
            }
            return 0;
        }

        pub fn numNonzero(self: *const Self) usize {
            var count: usize = 0;
            for (self.counts) |bin_count_value| count += @intFromBool(bin_count_value != 0);
            return count;
        }

        pub fn modalBinIndex(self: *const Self) usize {
            var maximum: Count = 0;
            var maximum_index: usize = 0;
            for (self.counts, 0..) |count, bin_index| {
                if (count > maximum) {
                    maximum = count;
                    maximum_index = bin_index;
                }
            }
            return maximum_index;
        }

        pub fn write(
            self: *const Self,
            writer: *std.Io.Writer,
            caption: []const u8,
            skip_zero: bool,
        ) std.Io.Writer.Error!void {
            try writer.print("\n{s} [{d}, modal idx {d}]\n", .{
                caption,
                capacity,
                self.modalBinIndex(),
            });
            const first = self.firstNonzero();
            if (first == capacity) return;
            const last = self.lastNonzero();
            for (first..last + 1) |bin_index| {
                const count = self.counts[bin_index];
                if (!skip_zero or count != 0) {
                    try writer.print(" {d:3}: {d}\n", .{ bin_index, count });
                }
            }
        }

        pub fn reset(self: *Self) void {
            @memset(&self.counts, 0);
        }

        fn index(bin_value: anytype) usize {
            const T = @TypeOf(bin_value);
            comptime switch (@typeInfo(T)) {
                .int, .comptime_int => {},
                else => @compileError("bin index must be an integer"),
            };
            switch (@typeInfo(T)) {
                .int => |info| if (info.signedness == .signed) {
                    std.debug.assert(bin_value >= 0);
                },
                .comptime_int => std.debug.assert(bin_value >= 0),
                else => unreachable,
            }
            const bin_index: usize = @intCast(bin_value);
            std.debug.assert(bin_index < capacity);
            return bin_index;
        }

        fn countValue(count: u32) Count {
            if (@bitSizeOf(Count) >= @bitSizeOf(u32)) return @intCast(count);
            return @truncate(count);
        }
    };
}

pub const Stats = struct {
    count_value: i64 = 0,
    minimum: f32 = std.math.floatMax(f32),
    maximum: f32 = -std.math.floatMax(f32),
    sum_log: f64 = 0,
    moment_1: f64 = 0,
    moment_2: f64 = 0,
    moment_3: f64 = 0,
    moment_4: f64 = 0,

    pub const max_count: i64 = 3_037_000_499;
    pub const no_count: u8 = 1;
    pub const no_mean_sd: u8 = 2;
    pub const no_min_max: u8 = 4;
    pub const no_skew_kurt: u8 = 8;
    pub const no_geometric_mean: u8 = 16;
    pub const all_exclusions: u8 = no_count |
        no_mean_sd |
        no_min_max |
        no_skew_kurt |
        no_geometric_mean;

    pub fn notify(self: *@This(), value: f32) void {
        std.debug.assert(self.count_value >= 0);
        std.debug.assert(self.count_value < max_count);
        self.count_value += 1;
        self.minimum = @min(self.minimum, value);
        self.maximum = @max(self.maximum, value);
        self.sum_log += @log(@as(f64, value));

        const count_f64: f64 = @floatFromInt(self.count_value);
        const delta = @as(f64, value) - self.moment_1;
        const delta_div_count = delta / count_f64;
        const delta2_count_minus_1_div_count = delta * (count_f64 - 1) * delta_div_count;
        const count_polynomial = count_f64 * count_f64 - 3 * count_f64 + 3;
        self.moment_1 += delta_div_count;
        self.moment_4 += delta_div_count *
            (delta_div_count *
                (delta2_count_minus_1_div_count * count_polynomial + 6 * self.moment_2) -
                4 * self.moment_3);
        self.moment_3 += delta_div_count *
            (delta2_count_minus_1_div_count * (count_f64 - 2) - 3 * self.moment_2);
        self.moment_2 += delta2_count_minus_1_div_count;
    }

    pub fn assimilate(self: *@This(), other: *const @This()) void {
        std.debug.assert(self.count_value >= 0);
        std.debug.assert(other.count_value >= 0);
        std.debug.assert(self.count_value <= max_count - other.count_value);
        const total_count = self.count_value + other.count_value;
        if (total_count == 0) return;

        self.minimum = @min(self.minimum, other.minimum);
        self.maximum = @max(self.maximum, other.maximum);
        self.sum_log += other.sum_log;

        const own_count: f64 = @floatFromInt(self.count_value);
        const other_count: f64 = @floatFromInt(other.count_value);
        const total_count_f64: f64 = @floatFromInt(total_count);
        const product = own_count * other_count;
        const count_squared = own_count * own_count;
        const other_count_squared = other_count * other_count;
        const total_count_squared = total_count_f64 * total_count_f64;
        const total_count_cubed = total_count_squared * total_count_f64;
        const inverse_total_count = 1 / total_count_f64;
        const inverse_total_count_squared = 1 / total_count_squared;

        const delta = other.moment_1 - self.moment_1;
        const delta_squared = delta * delta;
        const delta_cubed = delta * delta_squared;
        const delta_fourth = delta_squared * delta_squared;

        self.moment_1 = (own_count * self.moment_1 + other_count * other.moment_1) * inverse_total_count;
        const new_moment_2 = self.moment_2 + other.moment_2 +
            delta_squared * product * inverse_total_count;
        const new_moment_3 = self.moment_3 + other.moment_3 +
            delta_cubed * product * (own_count - other_count) * inverse_total_count_squared +
            3 * delta * (own_count * other.moment_2 - other_count * self.moment_2) * inverse_total_count;
        self.moment_4 += other.moment_4 +
            delta_fourth * product * (count_squared - product + other_count_squared) /
                total_count_cubed +
            6 * delta_squared *
                (count_squared * other.moment_2 + other_count_squared * self.moment_2) *
                inverse_total_count_squared +
            4 * delta * (own_count * other.moment_3 - other_count * self.moment_3) *
                inverse_total_count;
        self.moment_2 = new_moment_2;
        self.moment_3 = new_moment_3;
        self.count_value = total_count;
    }

    pub fn count(self: *const @This()) i64 {
        return self.count_value;
    }

    pub fn min(self: *const @This()) f32 {
        return self.minimum;
    }

    pub fn max(self: *const @This()) f32 {
        return self.maximum;
    }

    pub fn geometricMean(self: *const @This()) f64 {
        if (self.count_value == 0) return 0;
        return @exp(self.sum_log / @as(f64, @floatFromInt(self.count_value)));
    }

    pub fn mean(self: *const @This()) f64 {
        return self.moment_1;
    }

    pub fn sampleVariance(self: *const @This()) f64 {
        if (self.count_value == 0) return 0;
        return self.moment_2 / @as(f64, @floatFromInt(self.count_value));
    }

    pub fn variance(self: *const @This()) f64 {
        if (self.count_value == 0) return 0;
        if (self.count_value == 1) return self.moment_2;
        return self.moment_2 / @as(f64, @floatFromInt(self.count_value - 1));
    }

    pub fn standardDeviation(self: *const @This()) f64 {
        return @sqrt(self.variance());
    }

    pub fn sampleSkewness(self: *const @This()) f64 {
        if (@abs(self.moment_2) < 1e-7) return 0;
        const count_f64: f64 = @floatFromInt(self.count_value);
        return self.moment_3 * @sqrt(count_f64) /
            std.math.pow(f64, self.moment_2, 1.5);
    }

    pub fn skewness(self: *const @This()) f64 {
        if (self.count_value == 0) return 0;
        const count_f64: f64 = @floatFromInt(self.count_value);
        const ratio = (count_f64 - 1) / count_f64;
        return self.sampleSkewness() * std.math.pow(f64, ratio, 1.5);
    }

    pub fn sampleKurtosis(self: *const @This()) f64 {
        if (@abs(self.moment_2) < 1e-7) return 0;
        const count_f64: f64 = @floatFromInt(self.count_value);
        return self.moment_4 * count_f64 / (self.moment_2 * self.moment_2);
    }

    pub fn kurtosis(self: *const @This()) f64 {
        if (self.count_value == 0) return 0;
        const count_f64: f64 = @floatFromInt(self.count_value);
        const ratio = (count_f64 - 1) / count_f64;
        return self.sampleKurtosis() * ratio * ratio;
    }

    pub fn mu1(self: *const @This()) f64 {
        std.debug.assert(self.count_value != 0);
        return self.moment_1;
    }

    pub fn mu2(self: *const @This()) f64 {
        return self.centralMoment(self.moment_2);
    }

    pub fn mu3(self: *const @This()) f64 {
        return self.centralMoment(self.moment_3);
    }

    pub fn mu4(self: *const @This()) f64 {
        return self.centralMoment(self.moment_4);
    }

    pub fn write(
        self: *const @This(),
        writer: *std.Io.Writer,
        exclude: u8,
    ) std.Io.Writer.Error!void {
        if (self.count_value == 0) return writer.writeAll("(none)");
        if (exclude & no_count == 0) {
            try writer.print("Count={d:9} ", .{@as(u64, @intCast(self.count_value))});
        }
        if (exclude & no_mean_sd == 0) {
            try writer.writeAll("Mean=");
            try writeCScientific(writer, self.mean(), 10, 3);
            try writer.writeAll(" SD=");
            try writeCScientific(writer, self.standardDeviation(), 8, 2);
            try writer.writeByte(' ');
        }
        if (exclude & no_min_max == 0) {
            try writer.writeAll("Min=");
            try writeCScientific(writer, self.minimum, 10, 3);
            try writer.writeAll(" Max=");
            try writeCScientific(writer, self.maximum, 10, 3);
            try writer.writeByte(' ');
        }
        if (exclude & no_skew_kurt == 0) {
            try writer.print("Skew={d:5.2} Kurt={d:7.2} ", .{
                self.skewness(),
                self.kurtosis(),
            });
        }
        if (exclude & no_geometric_mean == 0) {
            try writer.print("GeoMean={d:9.6} ", .{self.geometricMean()});
        }
    }

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    fn centralMoment(self: *const @This(), moment: f64) f64 {
        std.debug.assert(self.count_value != 0);
        return moment / @as(f64, @floatFromInt(self.count_value));
    }
};

fn writeCScientific(
    writer: *std.Io.Writer,
    value: anytype,
    width: usize,
    precision: usize,
) std.Io.Writer.Error!void {
    var rendered_buffer: [std.fmt.float.min_buffer_size]u8 = undefined;
    const rendered = std.fmt.float.render(&rendered_buffer, value, .{
        .mode = .scientific,
        .precision = precision,
    }) catch unreachable;
    const exponent_marker = std.mem.lastIndexOfScalar(u8, rendered, 'e') orelse {
        return writer.alignBuffer(rendered, width, .right, ' ');
    };
    const exponent = std.fmt.parseInt(i32, rendered[exponent_marker + 1 ..], 10) catch unreachable;
    var exponent_buffer: [16]u8 = undefined;
    const exponent_digits = std.fmt.bufPrint(&exponent_buffer, "{d}", .{@abs(exponent)}) catch unreachable;
    const zero_count = if (exponent_digits.len < 2) 2 - exponent_digits.len else 0;
    const output_length = exponent_marker + 2 + zero_count + exponent_digits.len;
    if (output_length < width) try writer.splatByteAll(' ', width - output_length);
    try writer.writeAll(rendered[0..exponent_marker]);
    try writer.writeByte('e');
    try writer.writeByte(if (exponent < 0) '-' else '+');
    try writer.splatByteAll('0', zero_count);
    try writer.writeAll(exponent_digits);
}

fn requireBins(comptime capacity: usize, comptime Count: type) void {
    if (capacity == 0) @compileError("bins require a nonzero capacity");
    switch (@typeInfo(Count)) {
        .int => |info| if (info.signedness != .unsigned) {
            @compileError("bin counts must use an unsigned integer type");
        },
        else => @compileError("bin counts must use an unsigned integer type"),
    }
}
