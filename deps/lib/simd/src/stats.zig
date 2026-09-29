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

test "fixed bins notify, assimilate, summarize, and reset" {
    const Histogram = Bins(6);
    var bins = Histogram{};
    try std.testing.expectEqual(@as(usize, 6), bins.firstNonzero());
    try std.testing.expectEqual(@as(usize, 0), bins.lastNonzero());
    try std.testing.expectEqual(@as(usize, 0), bins.numNonzero());
    try std.testing.expectEqual(@as(usize, 0), bins.modalBinIndex());

    bins.notify(@as(i8, 4));
    bins.incrementBy(@as(u16, 2), 3);
    bins.incrementBy(4, 2);
    var other = Histogram{};
    other.incrementBy(3, 2);
    other.notify(4);
    bins.assimilate(&other);
    try std.testing.expectEqual(@as(u32, 3), bins.bin(2));
    try std.testing.expectEqual(@as(u32, 2), bins.bin(3));
    try std.testing.expectEqual(@as(u32, 4), bins.bin(4));
    try std.testing.expectEqual(@as(usize, 2), bins.firstNonzero());
    try std.testing.expectEqual(@as(usize, 4), bins.lastNonzero());
    try std.testing.expectEqual(@as(usize, 3), bins.numNonzero());
    try std.testing.expectEqual(@as(usize, 4), bins.modalBinIndex());

    bins.resetBin(4);
    try std.testing.expectEqual(@as(usize, 2), bins.modalBinIndex());
    bins.reset();
    try std.testing.expectEqual(@as(usize, 0), bins.numNonzero());
}

test "typed fixed bins preserve unsigned count wrapping" {
    var bins = TypedBins(2, u8){};
    bins.incrementBy(1, 300);
    try std.testing.expectEqual(@as(u8, 44), bins.bin(1));
    bins.incrementBy(1, 212);
    try std.testing.expectEqual(@as(u8, 0), bins.bin(1));
}

test "fixed bins writer preserves Highway text layout" {
    var bins = Bins(6){};
    bins.incrementBy(1, 2);
    bins.incrementBy(3, 5);
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try bins.write(&writer, "latency", false);
    try std.testing.expectEqualStrings(
        "\nlatency [6, modal idx 3]\n   1: 2\n   2: 0\n   3: 5\n",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&buffer);
    try bins.write(&writer, "latency", true);
    try std.testing.expectEqualStrings(
        "\nlatency [6, modal idx 3]\n   1: 2\n   3: 5\n",
        writer.buffered(),
    );
}

test "online statistics handle empty, singleton, and reset states" {
    var stats = Stats{};
    try std.testing.expectEqual(@as(i64, 0), stats.count());
    try std.testing.expectEqual(std.math.floatMax(f32), stats.min());
    try std.testing.expectEqual(-std.math.floatMax(f32), stats.max());
    try std.testing.expectEqual(@as(f64, 0), stats.geometricMean());
    try std.testing.expectEqual(@as(f64, 0), stats.mean());
    try std.testing.expectEqual(@as(f64, 0), stats.variance());
    try std.testing.expectEqual(@as(f64, 0), stats.standardDeviation());
    try std.testing.expectEqual(@as(f64, 0), stats.skewness());
    try std.testing.expectEqual(@as(f64, 0), stats.kurtosis());
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try stats.write(&writer, 0);
    try std.testing.expectEqualStrings("(none)", writer.buffered());

    stats.notify(4);
    try std.testing.expectEqual(@as(i64, 1), stats.count());
    try std.testing.expectEqual(@as(f32, 4), stats.min());
    try std.testing.expectEqual(@as(f32, 4), stats.max());
    try std.testing.expectEqual(@as(f64, 4), stats.mean());
    try std.testing.expectEqual(@as(f64, 0), stats.variance());
    try std.testing.expectEqual(@as(f64, 0), stats.skewness());
    try std.testing.expectEqual(@as(f64, 0), stats.kurtosis());
    try std.testing.expectApproxEqRel(@as(f64, 4), stats.geometricMean(), 1e-15);
    stats.reset();
    try std.testing.expectEqual(@as(i64, 0), stats.count());
}

test "online statistics assimilate partitions" {
    const values = [_]f32{ 1, 2, 2, 3, 5, 8, 13, 21 };
    var sequential = Stats{};
    for (values) |value| sequential.notify(value);
    var left = Stats{};
    for (values[0..3]) |value| left.notify(value);
    var right = Stats{};
    for (values[3..]) |value| right.notify(value);
    left.assimilate(&right);

    try std.testing.expectEqual(sequential.count(), left.count());
    try std.testing.expectEqual(sequential.min(), left.min());
    try std.testing.expectEqual(sequential.max(), left.max());
    try std.testing.expectApproxEqRel(sequential.geometricMean(), left.geometricMean(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.mean(), left.mean(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.variance(), left.variance(), 1e-14);
    try std.testing.expectApproxEqRel(sequential.skewness(), left.skewness(), 1e-14);
    try std.testing.expectApproxEqRel(sequential.kurtosis(), left.kurtosis(), 1e-14);
    try std.testing.expectApproxEqRel(sequential.mu1(), left.mu1(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.mu2(), left.mu2(), 1e-14);
    try std.testing.expectApproxEqRel(sequential.mu3(), left.mu3(), 1e-14);
    try std.testing.expectApproxEqRel(sequential.mu4(), left.mu4(), 1e-14);
}

test "online statistics match the pinned Highway oracle" {
    const values = [_]f32{ 1, 2, 2, 3, 5, 8, 13, 21 };
    var stats = Stats{};
    for (values) |value| stats.notify(value);

    try std.testing.expectEqual(@as(i64, 8), stats.count());
    try std.testing.expectEqual(@as(f32, 1), stats.min());
    try std.testing.expectEqual(@as(f32, 21), stats.max());
    try std.testing.expectEqual(@as(f64, 0x1.17295561888e1p+2), stats.geometricMean());
    try std.testing.expectEqual(@as(f64, 0x1.b8p+2), stats.mean());
    try std.testing.expectEqual(@as(f64, 0x1.52ep+5), stats.sampleVariance());
    try std.testing.expectEqual(@as(f64, 0x1.8349249249249p+5), stats.variance());
    try std.testing.expectEqual(@as(f64, 0x1.bd4c4807664aep+2), stats.standardDeviation());
    try std.testing.expectApproxEqAbs(@as(f64, 0x1.27fe45be6a283p+0), stats.sampleSkewness(), 4e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0x1.e488990369159p-1), stats.skewness(), 4e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0x1.86564df4935ecp+1), stats.sampleKurtosis(), 4e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0x1.2ada13af40d48p+1), stats.kurtosis(), 4e-15);
    try std.testing.expectEqual(@as(f64, 0x1.b8p+2), stats.mu1());
    try std.testing.expectEqual(@as(f64, 0x1.52ep+5), stats.mu2());
    try std.testing.expectEqual(@as(f64, 0x1.3ec3p+8), stats.mu3());
    try std.testing.expectEqual(@as(f64, 0x1.55fc8dp+12), stats.mu4());

    var buffer: [300]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try stats.write(&writer, 0);
    try std.testing.expectEqualStrings(
        "Count=        8 Mean= 6.875e+00 SD=6.96e+00 Min= 1.000e+00 Max= 2.100e+01 Skew= 0.95 Kurt=   2.33 GeoMean= 4.361898 ",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&buffer);
    try stats.write(&writer, Stats.no_count | Stats.no_min_max | Stats.no_geometric_mean);
    try std.testing.expectEqualStrings(
        "Mean= 6.875e+00 SD=6.96e+00 Skew= 0.95 Kurt=   2.33 ",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&buffer);
    try stats.write(&writer, Stats.all_exclusions | 0x80);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "online statistics assimilate empty states" {
    var empty = Stats{};
    var full = Stats{};
    for ([_]f32{ 2, 3, 7 }) |value| full.notify(value);
    const expected = full;
    full.assimilate(&empty);
    try std.testing.expectEqualDeep(expected, full);
    empty.assimilate(&expected);
    try std.testing.expectEqualDeep(expected, empty);
}

test "online statistics support self assimilation" {
    const values = [_]f32{ 1, 3, 7, 9 };
    var doubled = Stats{};
    for (values) |value| doubled.notify(value);
    doubled.assimilate(&doubled);
    var sequential = Stats{};
    for (0..2) |_| {
        for (values) |value| sequential.notify(value);
    }
    try std.testing.expectEqual(sequential.count(), doubled.count());
    try std.testing.expectEqual(sequential.min(), doubled.min());
    try std.testing.expectEqual(sequential.max(), doubled.max());
    try std.testing.expectApproxEqRel(sequential.geometricMean(), doubled.geometricMean(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.mean(), doubled.mean(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.mu2(), doubled.mu2(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.mu3(), doubled.mu3(), 1e-15);
    try std.testing.expectApproxEqRel(sequential.mu4(), doubled.mu4(), 1e-15);
}

test "geometric mean retains logarithm domain behavior" {
    var zero = Stats{};
    zero.notify(0);
    zero.notify(4);
    try std.testing.expectEqual(@as(f64, 0), zero.geometricMean());
    var negative = Stats{};
    negative.notify(-1);
    try std.testing.expect(std.math.isNan(negative.geometricMean()));
}
