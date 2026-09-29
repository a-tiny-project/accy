const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const base = @import("base.zig");
const random = @import("root.zig");

test {
    @import("test_discovery").discover(random);
    @import("test_discovery").discover(@This());
}

const entry = base.entry;
const kernel = base.kernel;
const tuning = base.tuning;

const Philox = random.Philox;
const Threefry = random.Threefry;
const Squares = random.Squares;
const Feistel = random.Feistel;
const PhiloxFold = random.PhiloxFold;
const ThreefryFold = random.ThreefryFold;
const SquaresFold = random.SquaresFold;
const PhiloxKeySplit = random.PhiloxKeySplit;
const PhiloxKeyUniform = random.PhiloxKeyUniform;
const PhiloxKeyCounterUniform = random.PhiloxKeyCounterUniform;
const Philox8F32 = random.Philox8F32;
const Threefry8F32 = random.Threefry8F32;
const PhiloxRuntimeFamilyI32 = random.PhiloxRuntimeFamilyI32;
const ThreefryRuntimeFamilyI32 = random.ThreefryRuntimeFamilyI32;
const SquaresRuntimeFamilyI32 = random.SquaresRuntimeFamilyI32;
const FeistelRuntimeFamilyI32 = random.FeistelRuntimeFamilyI32;
const PhiloxKeySplitRuntimeFamily = random.PhiloxKeySplitRuntimeFamily;
const PhiloxKeyUniformRuntimeFamilyF32 = random.PhiloxKeyUniformRuntimeFamilyF32;
const PhiloxKeyCounterUniformRuntimeFamilyF32 = random.PhiloxKeyCounterUniformRuntimeFamilyF32;
const PhiloxFoldRuntimeFamilyF32 = random.PhiloxFoldRuntimeFamilyF32;
const ThreefryFoldRuntimeFamilyI32 = random.ThreefryFoldRuntimeFamilyI32;
const SquaresFoldRuntimeFamilyF32 = random.SquaresFoldRuntimeFamilyF32;
const philox_lanes = random.philox_lanes;
const philox_default_rounds = random.philox_default_rounds;
const philox_family_version = random.philox_family_version;
const threefry_lanes = random.threefry_lanes;
const threefry_default_rounds = random.threefry_default_rounds;
const squares_default_key = random.squares_default_key;
const philoxBlock = random.philoxBlock;
const threefryBlock = random.threefryBlock;
const squaresBlock = random.squaresBlock;
const uniformFromBits = random.uniformFromBits;
const philoxInstanceTarget = random.philoxInstanceTarget;
const philoxInstanceEntryName = random.philoxInstanceEntryName;
const philoxFamilyTarget = random.philoxFamilyTarget;
const threefryInstanceTarget = random.threefryInstanceTarget;
const threefryFamilyTarget = random.threefryFamilyTarget;
const philoxFamilyTuningKey = random.philoxFamilyTuningKey;
const threefryFamilyTuningKey = random.threefryFamilyTuningKey;
const squaresFamilyTuningKey = random.squaresFamilyTuningKey;
const createPhiloxFamilyArtifact = random.createPhiloxFamilyArtifact;
const createPhiloxKeySplitFamilyArtifact = random.createPhiloxKeySplitFamilyArtifact;
const createPhiloxKeyUniformFamilyArtifact = random.createPhiloxKeyUniformFamilyArtifact;
const createPhiloxKeyCounterUniformFamilyArtifact = random.createPhiloxKeyCounterUniformFamilyArtifact;
const philoxFoldUniformReference = random.philoxFoldUniformReference;
const threefryFoldBitsReference = random.threefryFoldBitsReference;
const createPhiloxFoldFamilyArtifact = random.createPhiloxFoldFamilyArtifact;
const philoxFoldRuntimeArguments = random.philoxFoldRuntimeArguments;
const philoxFoldFamilyTuningKey = random.philoxFoldFamilyTuningKey;
const threefryFoldFamilyTuningKey = random.threefryFoldFamilyTuningKey;
const squaresFoldFamilyTuningKey = random.squaresFoldFamilyTuningKey;
const squaresFoldUniformReference = random.squaresFoldUniformReference;
const createSquaresFamilyArtifact = random.createSquaresFamilyArtifact;
const squaresFamilySpecialization = random.squaresFamilySpecialization;
const squaresInstanceFromSpecialization = random.squaresInstanceFromSpecialization;
const philoxInstanceFromSpecialization = random.philoxInstanceFromSpecialization;
const threefryInstanceFromSpecialization = random.threefryInstanceFromSpecialization;
const philoxFamilySpecialization = random.philoxFamilySpecialization;
const threefryFamilySpecialization = random.threefryFamilySpecialization;
const feistelFamilyTarget = random.feistelFamilyTarget;
const feistelFamilyEntryName = random.feistelFamilyEntryName;
const feistelPermuteReference = random.feistelPermuteReference;
const feistelInstanceValid = random.feistelInstanceValid;
const feistelDomainBits = random.feistelDomainBits;
const feistelRuntimeArguments = random.feistelRuntimeArguments;
const Key = gpu_abi.Key;

fn randomFamilyTuningTestCapabilities(device_id: u32) gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "random-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = device_id,
    } };
}

test "random philox reference matches Random123 known answers" {
    try std.testing.expectEqual(
        [4]u32{ 0x6627e8d5, 0xe169c58d, 0xbc57ac4c, 0x9b00dbd8 },
        philoxBlock(10, .{ 0, 0, 0, 0 }, .{ 0, 0 }),
    );
    try std.testing.expectEqual(
        [4]u32{ 0x408f276d, 0x41c83b0e, 0xa20bc7c6, 0x6d5451fd },
        philoxBlock(10, .{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff }, .{ 0xffffffff, 0xffffffff }),
    );
    try std.testing.expectEqual(
        [4]u32{ 0xd16cfe09, 0x94fdcceb, 0x5001e420, 0x24126ea1 },
        philoxBlock(10, .{ 0x243f6a88, 0x85a308d3, 0x13198a2e, 0x03707344 }, .{ 0xa4093822, 0x299f31d0 }),
    );
    try std.testing.expectEqual(
        [4]u32{ 0x5f6fb709, 0x0d893f64, 0x4f121f81, 0x4f730a48 },
        philoxBlock(7, .{ 0, 0, 0, 0 }, .{ 0, 0 }),
    );
    try std.testing.expectEqual(
        [4]u32{ 0x5207ddc2, 0x45165e59, 0x4d8ee751, 0x8c52f662 },
        philoxBlock(7, .{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff }, .{ 0xffffffff, 0xffffffff }),
    );
    try std.testing.expectEqual(
        [4]u32{ 0x4dfccaba, 0x190a87f0, 0xc47362ba, 0xb6b5242a },
        philoxBlock(7, .{ 0x243f6a88, 0x85a308d3, 0x13198a2e, 0x03707344 }, .{ 0xa4093822, 0x299f31d0 }),
    );
}

test "random threefry reference matches Random123 known answers" {
    try std.testing.expectEqual(
        [2]u32{ 0x6b200159, 0x99ba4efe },
        threefryBlock(20, .{ 0, 0 }, .{ 0, 0 }),
    );
    try std.testing.expectEqual(
        [2]u32{ 0x1cb996fc, 0xbb002be7 },
        threefryBlock(20, .{ 0xffffffff, 0xffffffff }, .{ 0xffffffff, 0xffffffff }),
    );
    try std.testing.expectEqual(
        [2]u32{ 0xc4923a9c, 0x483df7a0 },
        threefryBlock(20, .{ 0x243f6a88, 0x85a308d3 }, .{ 0x13198a2e, 0x03707344 }),
    );
    try std.testing.expectEqual(
        [2]u32{ 0x9d1c5ec6, 0x8bd50731 },
        threefryBlock(13, .{ 0, 0 }, .{ 0, 0 }),
    );
    try std.testing.expectEqual(
        [2]u32{ 0xfd36d048, 0x2d17272c },
        threefryBlock(13, .{ 0xffffffff, 0xffffffff }, .{ 0xffffffff, 0xffffffff }),
    );
    try std.testing.expectEqual(
        [2]u32{ 0xba3e4725, 0xf27d669e },
        threefryBlock(13, .{ 0x243f6a88, 0x85a308d3 }, .{ 0x13198a2e, 0x03707344 }),
    );
}

test "random uniform conversion stays in the unit interval" {
    try std.testing.expectEqual(@as(f32, 0.0), uniformFromBits(0));
    const top = uniformFromBits(0xffffffff);
    try std.testing.expect(top < 1.0);
    try std.testing.expect(top >= 0.0);
    const mid = uniformFromBits(0x80000000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid, 0.0000002);
}

test "random philox entry writes Random123 words through the uniform map on CPU" {
    var dst = @as([8]f32, @splat(0));

    try Philox8F32.runCpu(std.testing.allocator, Philox8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentI32(0),
        kernel.argumentI32(0),
    });

    var expected: [8]f32 = undefined;
    for (0..2) |generator| {
        const words = philoxBlock(philox_default_rounds, .{ @intCast(generator), 0, 0, 0 }, .{ 0, 0 });
        for (words, 0..) |word, lane| expected[generator * 4 + lane] = uniformFromBits(word);
    }
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "random threefry entry matches reference blocks on CPU" {
    var dst = @as([8]f32, @splat(0));

    try Threefry8F32.runCpu(std.testing.allocator, Threefry8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentI32(7),
        kernel.argumentI32(11),
    });

    var expected: [8]f32 = undefined;
    for (0..4) |generator| {
        const words = threefryBlock(threefry_default_rounds, .{ @intCast(generator), 0 }, .{ 7, 11 });
        for (words, 0..) |word, lane| expected[generator * 2 + lane] = uniformFromBits(word);
    }
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "random philox runtime family emits raw bits with tail guard" {
    const allocator = std.testing.allocator;
    const compiled = Philox{ .count = 1, .dtype = .i32, .threads = 4 };
    const runtime = Philox{ .count = 10, .dtype = .i32, .threads = 4, .seed = 0xdeadbeef00c0ffee };

    var graph = try PhiloxRuntimeFamilyI32.build(allocator, PhiloxRuntimeFamilyI32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([12]i32, @splat(0));

    const launch_value = try entry.runtimeLaunch1D(runtime.generators(), runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
        kernel.argumentI32(@bitCast(runtime.seedLo())),
        kernel.argumentI32(@bitCast(runtime.seedHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected = @as([12]i32, @splat(0));
    for (0..3) |generator| {
        const words = philoxBlock(
            philox_default_rounds,
            .{ @intCast(generator), 0, 0, 0 },
            .{ runtime.seedLo(), runtime.seedHi() },
        );
        for (words, 0..) |word, lane| {
            const element = generator * 4 + lane;
            if (element < runtime.count) expected[element] = @bitCast(word);
        }
    }
    try std.testing.expectEqualSlices(i32, expected[0..], dst[0..]);
}

test "random philox key families split keys and consume key tensors on CPU" {
    const allocator = std.testing.allocator;
    const split_instance = PhiloxKeySplit{ .count = 8, .threads = 4, .rounds = 10 };
    const uniform_instance = PhiloxKeyUniform{ .count = 8, .threads = 4, .rounds = 10 };
    const seed = Key.init(0x01234567_89abcdef);

    var split_graph = try PhiloxKeySplitRuntimeFamily.build(allocator, PhiloxKeySplitRuntimeFamily.Limits.testing, split_instance);
    defer split_graph.deinit();
    var uniform_graph = try PhiloxKeyUniformRuntimeFamilyF32.build(allocator, PhiloxKeyUniformRuntimeFamilyF32.Limits.testing, uniform_instance);
    defer uniform_graph.deinit();

    var src = [_]Key{seed};
    var keys = @as([8]Key, @splat(Key.init(0)));
    const split_launch = try entry.runtimeLaunch1D(split_instance.generators(), split_instance.threads);
    try split_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(Key, keys[0..]),
        kernel.argumentBuffer(Key, src[0..]),
        kernel.argumentI32(@intCast(split_instance.count)),
    }, .{
        .grid = split_launch.grid,
        .block = split_launch.threadgroup,
    });

    for (keys, 0..) |key_value, index| {
        const words = philoxBlock(
            split_instance.rounds,
            .{ @intCast(index), 0, 0, 0 },
            .{ seed.lo(), seed.hi() },
        );
        try std.testing.expectEqual(Key.fromWords(words[0], words[1]), key_value);
    }

    var dst = @as([8]f32, @splat(-1.0));
    const uniform_launch = try entry.runtimeLaunch1D(uniform_instance.generators(), uniform_instance.threads);
    try uniform_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(Key, keys[0..]),
        kernel.argumentI32(@intCast(uniform_instance.count)),
    }, .{
        .grid = uniform_launch.grid,
        .block = uniform_launch.threadgroup,
    });

    for (keys, 0..) |key_value, index| {
        const words = philoxBlock(
            uniform_instance.rounds,
            .{ 0, 0, 0, 0 },
            .{ key_value.lo(), key_value.hi() },
        );
        try std.testing.expectEqual(uniformFromBits(words[0]), dst[index]);
        try std.testing.expect(dst[index] >= 0.0);
        try std.testing.expect(dst[index] < 1.0);
    }
}

test "random threefry runtime family emits raw bits with tail guard" {
    const allocator = std.testing.allocator;
    const compiled = Threefry{ .count = 1, .dtype = .i32, .threads = 4 };
    const runtime = Threefry{ .count = 7, .dtype = .i32, .threads = 4, .seed = 0x0123456789abcdef };

    var graph = try ThreefryRuntimeFamilyI32.build(allocator, ThreefryRuntimeFamilyI32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([8]i32, @splat(0));

    const launch_value = try entry.runtimeLaunch1D(runtime.generators(), runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
        kernel.argumentI32(@bitCast(runtime.seedLo())),
        kernel.argumentI32(@bitCast(runtime.seedHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected = @as([8]i32, @splat(0));
    for (0..4) |generator| {
        const words = threefryBlock(
            threefry_default_rounds,
            .{ @intCast(generator), 0 },
            .{ runtime.seedLo(), runtime.seedHi() },
        );
        for (words, 0..) |word, lane| {
            const element = generator * 2 + lane;
            if (element < runtime.count) expected[element] = @bitCast(word);
        }
    }
    try std.testing.expectEqualSlices(i32, expected[0..], dst[0..]);
}

test "random feistel validates only balanced power-of-two i32 domains" {
    try std.testing.expectEqual(@as(?u6, 6), feistelDomainBits(64));
    try std.testing.expectEqual(@as(?u6, null), feistelDomainBits(63));
    try std.testing.expectEqual(@as(?u6, null), feistelDomainBits(128));
    try std.testing.expect(feistelInstanceValid(.{ .count = 64, .threads = 32 }));
    try std.testing.expect(!feistelInstanceValid(.{ .count = 128, .threads = 32 }));
    try std.testing.expect(!feistelInstanceValid(.{ .count = 64, .threads = 0 }));
    try std.testing.expect(!feistelInstanceValid(.{ .count = 64, .rounds = 0, .threads = 32 }));
    try std.testing.expect(!feistelInstanceValid(.{ .count = 64, .dtype = .f32, .threads = 32 }));
}

test "random feistel reference is bijective on balanced domain" {
    const count = 64;
    const bits = feistelDomainBits(count).?;
    var seen = @as([count]bool, @splat(false));
    for (0..count) |index| {
        const mapped = feistelPermuteReference(@intCast(index), 6, 0x10203040_55667788, bits);
        try std.testing.expect(mapped < count);
        try std.testing.expect(!seen[mapped]);
        seen[mapped] = true;
    }
    for (seen) |hit| try std.testing.expect(hit);
}

test "random feistel runtime family emits permutation stream on CPU" {
    const allocator = std.testing.allocator;
    const instance = Feistel{ .count = 64, .rounds = 6, .seed = 0x10203040_55667788, .threads = 32 };

    var graph = try FeistelRuntimeFamilyI32.build(allocator, FeistelRuntimeFamilyI32.Limits.testing, instance);
    defer graph.deinit();

    var dst = @as([65]i32, @splat(-1));

    const launch_value = try entry.runtimeLaunch1D(instance.count, instance.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentI32(@intCast(instance.count)),
        kernel.argumentI32(@bitCast(instance.seedLo())),
        kernel.argumentI32(@bitCast(instance.seedHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected = @as([65]i32, @splat(-1));
    const bits = instance.domainBits().?;
    for (0..instance.count) |element| {
        expected[element] = @intCast(feistelPermuteReference(@intCast(element), instance.rounds, instance.seed, bits));
    }
    try std.testing.expectEqualSlices(i32, expected[0..], dst[0..]);
}

test "random feistel family identity is stable" {
    const instance = Feistel{ .count = 64, .rounds = 6, .seed = 0x10203040_55667788, .threads = 32 };

    const target = try feistelFamilyTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("accy.kernel.random.feistel_family_6b_6r_32_i32", target);

    const entry_name = try feistelFamilyEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(entry_name);
    try std.testing.expectEqualStrings("accy_kernel_random_feistel_family_6b_6r_32_i32", entry_name);

    const args = try feistelRuntimeArguments(instance);
    try std.testing.expectEqual(@as(u32, 64), args[0].u32);
    try std.testing.expectEqual(instance.seedLo(), args[1].u32);
    try std.testing.expectEqual(instance.seedHi(), args[2].u32);

    try std.testing.expectEqual(@as(u32, 1), random.feistel_family_version);
}

test "random family instance identity matches fixed entry strings" {
    const philox_instance = Philox{ .count = 8, .threads = 2 };

    const philox_target = try philoxInstanceTarget(std.testing.allocator, philox_instance);
    defer std.testing.allocator.free(philox_target);
    try std.testing.expectEqualStrings(Philox8F32.target, philox_target);

    const philox_entry_name = try philoxInstanceEntryName(std.testing.allocator, philox_instance);
    defer std.testing.allocator.free(philox_entry_name);
    try std.testing.expectEqualStrings(Philox8F32.name, philox_entry_name);

    try std.testing.expectEqual(Philox8F32.version, philox_family_version);

    const fresh = Philox{ .count = 1 << 20, .rounds = 7, .threads = 128 };
    const family_target = try philoxFamilyTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.random.philox_family_7r_128_f32", family_target);

    const threefry_instance = Threefry{ .count = 8, .threads = 4 };
    const threefry_target = try threefryInstanceTarget(std.testing.allocator, threefry_instance);
    defer std.testing.allocator.free(threefry_target);
    try std.testing.expectEqualStrings(Threefry8F32.target, threefry_target);

    const threefry_family_target = try threefryFamilyTarget(std.testing.allocator, .{ .count = 64, .rounds = 13, .threads = 64, .dtype = .i32 });
    defer std.testing.allocator.free(threefry_family_target);
    try std.testing.expectEqualStrings("accy.kernel.random.threefry_family_13r_64_i32", threefry_family_target);
}

test "random family tuning keys distinguish generators rounds and device" {
    const allocator = std.testing.allocator;
    const device = tuning.deviceFingerprint(randomFamilyTuningTestCapabilities(0x2684));

    const keys = [_]tuning.FamilyTuningKey{
        try philoxFamilyTuningKey(allocator, device, .{ .count = 1024 }),
        try threefryFamilyTuningKey(allocator, device, .{ .count = 1024 }),
        try squaresFamilyTuningKey(allocator, device, .{ .count = 1024 }),
    };
    for (keys, 0..) |key, index| {
        for (keys[index + 1 ..]) |other| {
            try std.testing.expect(!key.eql(other));
        }
    }

    const fewer_rounds = try philoxFamilyTuningKey(allocator, device, .{ .count = 1024, .rounds = 7 });
    try std.testing.expect(!fewer_rounds.eql(keys[0]));
    try std.testing.expectEqual(keys[0].family_fingerprint, fewer_rounds.family_fingerprint);
    try std.testing.expect(keys[0].operation_fingerprint != fewer_rounds.operation_fingerprint);

    const other_device = try philoxFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(randomFamilyTuningTestCapabilities(0x1b80)),
        .{ .count = 1024 },
    );
    try std.testing.expect(!other_device.eql(keys[0]));
    try std.testing.expectEqual(keys[0].family_fingerprint, other_device.family_fingerprint);
    try std.testing.expectEqual(keys[0].operation_fingerprint, other_device.operation_fingerprint);
}

test "random philox family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = Philox{ .count = 1024, .threads = 64 };

    var family_artifact = try createPhiloxFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.random.philox_family_10r_64_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_random_philox_family_10r_64_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 4), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.f32));
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("philox", profile.name);
    try std.testing.expectEqual(@as(usize, 1), profile.dimensions.len);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 0), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 256), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
}

test "random philox key family artifacts carry key dtype contracts" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var split_artifact = try createPhiloxKeySplitFamilyArtifact(
        allocator,
        state.handle(),
        .{ .count = 1024, .threads = 64 },
        .{ .limits = .testing },
    );
    defer split_artifact.deinit();
    const split_entry = split_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.random.philox_key_split_family_10r_64_key", split_entry.target);
    try std.testing.expectEqual(@as(u32, 3), split_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 1), split_entry.runtime_scalar_argument_count);
    try std.testing.expect(split_entry.required_dtypes.contains(.key));

    var uniform_artifact = try createPhiloxKeyUniformFamilyArtifact(
        allocator,
        state.handle(),
        .{ .count = 1024, .threads = 64, .dtype = .f32 },
        .{ .limits = .testing },
    );
    defer uniform_artifact.deinit();
    const uniform_entry = uniform_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.random.philox_key_uniform_family_10r_64_f32", uniform_entry.target);
    try std.testing.expectEqual(@as(u32, 3), uniform_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 1), uniform_entry.runtime_scalar_argument_count);
    try std.testing.expect(uniform_entry.required_dtypes.contains(.key));
    try std.testing.expect(uniform_entry.required_dtypes.contains(.f32));

    var counter_artifact = try createPhiloxKeyCounterUniformFamilyArtifact(
        allocator,
        state.handle(),
        .{ .count = 1024, .threads = 64, .dtype = .f32 },
        .{ .limits = .testing },
    );
    defer counter_artifact.deinit();
    const counter_entry = counter_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.random.philox_key_counter_uniform_family_10r_64_f32", counter_entry.target);
    try std.testing.expectEqual(@as(u32, 4), counter_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 1), counter_entry.runtime_scalar_argument_count);
    try std.testing.expect(counter_entry.required_dtypes.contains(.key));
    try std.testing.expect(counter_entry.required_dtypes.contains(.i32));
    try std.testing.expect(counter_entry.required_dtypes.contains(.f32));
}

test "random philox key counter uniform samples from scalar key and counter on CPU" {
    const allocator = std.testing.allocator;
    const compiled = PhiloxKeyCounterUniform{ .count = 1, .threads = 4 };
    const runtime = PhiloxKeyCounterUniform{ .count = 6, .threads = 4 };
    const seed = Key.init(0x01234567_89abcdef);
    var counter = [_]i32{3};

    var graph = try PhiloxKeyCounterUniformRuntimeFamilyF32.build(allocator, PhiloxKeyCounterUniformRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([8]f32, @splat(-1.0));
    var keys = [_]Key{seed};

    const launch_value = try entry.runtimeLaunch1D(runtime.count, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(Key, keys[0..]),
        kernel.argumentBuffer(i32, counter[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    for (0..runtime.count) |index| {
        const words = philoxBlock(
            philox_default_rounds,
            .{ @intCast(index), @bitCast(counter[0]), 0, 0 },
            .{ seed.lo(), seed.hi() },
        );
        try std.testing.expectApproxEqAbs(uniformFromBits(words[0]), dst[index], 0.0);
    }
    try std.testing.expectEqual(@as(f32, -1.0), dst[6]);
}

test "random philox fold family accumulates uniform samples on CPU" {
    const allocator = std.testing.allocator;
    const compiled = PhiloxFold{ .count = 1, .threads = 4 };
    const runtime = PhiloxFold{ .count = 6, .samples = 5, .threads = 4, .seed = 0x00c0ffee };

    var graph = try PhiloxFoldRuntimeFamilyF32.build(allocator, PhiloxFoldRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([8]f32, @splat(-1.0));

    const launch_value = try entry.runtimeLaunch1D(runtime.count, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
        kernel.argumentI32(@intCast(runtime.samples)),
        kernel.argumentI32(@bitCast(runtime.seedLo())),
        kernel.argumentI32(@bitCast(runtime.seedHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    for (0..6) |output| {
        const expected = philoxFoldUniformReference(
            philox_default_rounds,
            @intCast(output),
            runtime.samples,
            .{ runtime.seedLo(), runtime.seedHi() },
        );
        try std.testing.expectEqual(expected, dst[output]);
        try std.testing.expect(dst[output] >= 0.0);
        try std.testing.expect(dst[output] < @as(f32, @floatFromInt(runtime.samples * philox_lanes)));
    }
    try std.testing.expectEqual(@as(f32, -1.0), dst[6]);
    try std.testing.expectEqual(@as(f32, -1.0), dst[7]);
}

test "random threefry fold family xors raw words on CPU" {
    const allocator = std.testing.allocator;
    const compiled = ThreefryFold{ .count = 1, .dtype = .i32, .threads = 4 };
    const runtime = ThreefryFold{ .count = 5, .samples = 7, .dtype = .i32, .threads = 4, .seed = 0xfeedface12345678 };

    var graph = try ThreefryFoldRuntimeFamilyI32.build(allocator, ThreefryFoldRuntimeFamilyI32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([8]i32, @splat(0));

    const launch_value = try entry.runtimeLaunch1D(runtime.count, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
        kernel.argumentI32(@intCast(runtime.samples)),
        kernel.argumentI32(@bitCast(runtime.seedLo())),
        kernel.argumentI32(@bitCast(runtime.seedHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    for (0..5) |output| {
        const expected = threefryFoldBitsReference(
            threefry_default_rounds,
            @intCast(output),
            runtime.samples,
            .{ runtime.seedLo(), runtime.seedHi() },
        );
        try std.testing.expectEqual(@as(i32, @bitCast(expected)), dst[output]);
    }
}

test "random fold family artifact carries samples scalar in launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = PhiloxFold{ .count = 4096, .samples = 16, .rounds = 7, .threads = 128 };

    var family_artifact = try createPhiloxFoldFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.random.philox_fold_family_7r_128_f32", family_entry.target);
    try std.testing.expectEqual(@as(u32, 5), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 4), family_entry.runtime_scalar_argument_count);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
    try std.testing.expectEqual(@as(usize, 1), profile.dimensions[1].runtime_scalar_argument_index);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 128), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 0), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 128), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }

    const arguments = try philoxFoldRuntimeArguments(instance);
    try std.testing.expectEqual(@as(u32, 4096), arguments[0].u32);
    try std.testing.expectEqual(@as(u32, 16), arguments[1].u32);
}

test "random fold family tuning keys separate fills from folds" {
    const allocator = std.testing.allocator;
    const caps = randomFamilyTuningTestCapabilities(0x2684);
    const device = tuning.deviceFingerprint(caps);

    const fill_key = try philoxFamilyTuningKey(allocator, device, .{ .count = 4096 });
    const fold_key = try philoxFoldFamilyTuningKey(allocator, device, .{ .count = 4096, .samples = 1 });
    try std.testing.expect(!fill_key.eql(fold_key));
    try std.testing.expect(fill_key.operation_fingerprint != fold_key.operation_fingerprint);

    const more_samples = try philoxFoldFamilyTuningKey(allocator, device, .{ .count = 4096, .samples = 8 });
    try std.testing.expect(!fold_key.eql(more_samples));
    try std.testing.expectEqual(fold_key.family_fingerprint, more_samples.family_fingerprint);
    try std.testing.expectEqual(fold_key.operation_fingerprint, more_samples.operation_fingerprint);

    const fewer_rounds = try philoxFoldFamilyTuningKey(allocator, device, .{ .count = 4096, .samples = 1, .rounds = 7 });
    try std.testing.expect(fold_key.operation_fingerprint != fewer_rounds.operation_fingerprint);

    const threefry_key = try threefryFoldFamilyTuningKey(allocator, device, .{ .count = 4096 });
    const squares_key = try squaresFoldFamilyTuningKey(allocator, device, .{ .count = 4096 });
    try std.testing.expect(!threefry_key.eql(squares_key));

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = fold_key,
        .target = "accy.kernel.random.philox_fold_family_256_f32",
        .winner_median_ns = 700,
        .runner_up_median_ns = 1000,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });
    const hit_key = try philoxFoldFamilyTuningKey(allocator, reader.device_fingerprint, .{ .count = 4096, .samples = 1 });
    const hit = reader.table.find(hit_key) orelse return error.TestExpectedTuningRecord;
    try std.testing.expectEqualStrings("accy.kernel.random.philox_fold_family_256_f32", hit.target);
    try std.testing.expect(reader.table.find(fill_key) == null);
}

test "random squares reference matches computed anchors for the documented key" {
    try std.testing.expectEqual(@as(u32, 0x58db6965), squaresBlock(0, squares_default_key));
    try std.testing.expectEqual(@as(u32, 0x3b63969b), squaresBlock(1, squares_default_key));
    try std.testing.expectEqual(@as(u32, 0xbcd3723e), squaresBlock(2, squares_default_key));
    try std.testing.expectEqual(@as(u32, 0xe617d09b), squaresBlock(0xffffffffffffffff, squares_default_key));
}

test "random squares runtime family emits raw bits with tail guard on CPU" {
    const allocator = std.testing.allocator;
    const compiled = Squares{ .count = 1, .dtype = .i32, .threads = 4 };
    const runtime = Squares{ .count = 6, .dtype = .i32, .threads = 4 };

    var graph = try SquaresRuntimeFamilyI32.build(allocator, SquaresRuntimeFamilyI32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([8]i32, @splat(0));

    const launch_value = try entry.runtimeLaunch1D(runtime.count, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
        kernel.argumentI32(@bitCast(runtime.keyLo())),
        kernel.argumentI32(@bitCast(runtime.keyHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    for (0..6) |element| {
        const expected = squaresBlock(@intCast(element), runtime.key);
        try std.testing.expectEqual(@as(i32, @bitCast(expected)), dst[element]);
    }
    try std.testing.expectEqual(@as(i32, 0), dst[6]);
    try std.testing.expectEqual(@as(i32, 0), dst[7]);
}

test "random squares fold family accumulates uniform samples on CPU" {
    const allocator = std.testing.allocator;
    const compiled = SquaresFold{ .count = 1, .threads = 4 };
    const runtime = SquaresFold{ .count = 5, .samples = 6, .threads = 4 };

    var graph = try SquaresFoldRuntimeFamilyF32.build(allocator, SquaresFoldRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var dst = @as([8]f32, @splat(-1.0));

    const launch_value = try entry.runtimeLaunch1D(runtime.count, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentI32(@intCast(runtime.count)),
        kernel.argumentI32(@intCast(runtime.samples)),
        kernel.argumentI32(@bitCast(runtime.keyLo())),
        kernel.argumentI32(@bitCast(runtime.keyHi())),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    for (0..5) |output| {
        const expected = squaresFoldUniformReference(@intCast(output), runtime.samples, runtime.key);
        try std.testing.expectEqual(expected, dst[output]);
    }
    try std.testing.expectEqual(@as(f32, -1.0), dst[5]);
}

test "random squares family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = Squares{ .count = 4096, .threads = 128 };

    var family_artifact = try createSquaresFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.random.squares_family_128_f32", family_entry.target);
    try std.testing.expectEqual(@as(u32, 4), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);

    var owned = try squaresFamilySpecialization(allocator, instance);
    defer owned.deinit();
    const recovered = squaresInstanceFromSpecialization(owned.value) orelse return error.TestExpectedSquaresInstance;
    try std.testing.expectEqual(instance.count, recovered.count);
    try std.testing.expectEqual(instance.threads, recovered.threads);
    try std.testing.expectEqual(@as(?Philox, null), philoxInstanceFromSpecialization(owned.value));
}

test "random reference streams keep every bit position near balance" {
    const words_per_algorithm: u32 = 1 << 18;
    var ones = @as([32]u64, @splat(0));

    var counter: u32 = 0;
    var produced: u32 = 0;
    while (produced < words_per_algorithm) : (counter += 1) {
        const words = philoxBlock(philox_default_rounds, .{ counter, 0, 0, 0 }, .{ 0x9e3779b9, 0x7f4a7c15 });
        for (words) |word| {
            for (0..32) |bit| ones[bit] += (word >> @intCast(bit)) & 1;
        }
        produced += philox_lanes;
    }
    try expectBitBalance(&ones, produced);

    ones = @as([32]u64, @splat(0));
    counter = 0;
    produced = 0;
    while (produced < words_per_algorithm) : (counter += 1) {
        const words = threefryBlock(threefry_default_rounds, .{ counter, 0 }, .{ 0x243f6a88, 0x85a308d3 });
        for (words) |word| {
            for (0..32) |bit| ones[bit] += (word >> @intCast(bit)) & 1;
        }
        produced += threefry_lanes;
    }
    try expectBitBalance(&ones, produced);

    ones = @as([32]u64, @splat(0));
    counter = 0;
    while (counter < words_per_algorithm) : (counter += 1) {
        const word = squaresBlock(counter, squares_default_key);
        for (0..32) |bit| ones[bit] += (word >> @intCast(bit)) & 1;
    }
    try expectBitBalance(&ones, words_per_algorithm);
}

fn expectBitBalance(ones: *const [32]u64, words: u32) !void {
    const half: f64 = @as(f64, @floatFromInt(words)) / 2.0;
    const tolerance = half * 0.02;
    for (ones) |count| {
        const deviation = @abs(@as(f64, @floatFromInt(count)) - half);
        try std.testing.expect(deviation < tolerance);
    }
}

test "random instances round-trip through specializations" {
    const philox_instance = Philox{ .count = 4096, .rounds = 7, .dtype = .i32, .threads = 128 };
    var philox_owned = try philoxFamilySpecialization(std.testing.allocator, philox_instance);
    defer philox_owned.deinit();

    const philox_recovered = philoxInstanceFromSpecialization(philox_owned.value) orelse return error.TestExpectedPhiloxInstance;
    try std.testing.expectEqual(philox_instance.count, philox_recovered.count);
    try std.testing.expectEqual(philox_instance.rounds, philox_recovered.rounds);
    try std.testing.expectEqual(philox_instance.dtype, philox_recovered.dtype);
    try std.testing.expectEqual(philox_instance.threads, philox_recovered.threads);
    try std.testing.expectEqual(@as(?Threefry, null), threefryInstanceFromSpecialization(philox_owned.value));

    const threefry_instance = Threefry{ .count = 1000, .rounds = 13, .threads = 64 };
    var threefry_owned = try threefryFamilySpecialization(std.testing.allocator, threefry_instance);
    defer threefry_owned.deinit();

    const threefry_recovered = threefryInstanceFromSpecialization(threefry_owned.value) orelse return error.TestExpectedThreefryInstance;
    try std.testing.expectEqual(threefry_instance.count, threefry_recovered.count);
    try std.testing.expectEqual(threefry_instance.rounds, threefry_recovered.rounds);
    try std.testing.expectEqual(threefry_instance.dtype, threefry_recovered.dtype);
    try std.testing.expectEqual(threefry_instance.threads, threefry_recovered.threads);
    try std.testing.expectEqual(@as(?Philox, null), philoxInstanceFromSpecialization(threefry_owned.value));

    try std.testing.expectEqual(@as(?Philox, null), philoxInstanceFromSpecialization(.{}));
}

test "accy kernel library random declaration coverage" {
    std.testing.refAllDecls(random);
    std.testing.refAllDecls(@This());
}
