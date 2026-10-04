const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const linux = @import("linux.zig");

pub const required_capabilities = switch (builtin.os.tag) {
    .linux => capabilities.noLibc(&.{ .process, .random }),
    else => capabilities.host(&.{ .process, .random }),
};

pub const SecureError = error{Unavailable};

const csprng_u16_reseed_draws: u32 = 1 << 16;

const SystemEntropy = struct {
    fn fill(_: *const SystemEntropy, buffer: []u8) SecureError!void {
        return secureBytes(buffer);
    }
};

const CsprngU16Stream = struct {
    generator: std.Random.DefaultCsprng = undefined,
    process_epoch: u64 = 0,
    draws: u32 = 0,
    initialized: bool = false,

    fn next(self: *CsprngU16Stream, epoch: u64, entropy: anytype) SecureError!u16 {
        std.debug.assert(self.draws <= csprng_u16_reseed_draws);
        if (!self.initialized or self.process_epoch != epoch or
            self.draws == csprng_u16_reseed_draws)
        {
            try self.reseed(epoch, entropy);
        }
        var bytes: [2]u8 = undefined;
        self.generator.fill(&bytes);
        self.draws += 1;
        std.debug.assert(self.draws <= csprng_u16_reseed_draws);
        return std.mem.readInt(u16, &bytes, .native);
    }

    fn reseed(self: *CsprngU16Stream, epoch: u64, entropy: anytype) SecureError!void {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        try entropy.fill(&seed);
        self.generator = .init(seed);
        self.process_epoch = epoch;
        self.draws = 0;
        self.initialized = true;
    }
};

const TestEntropy = struct {
    successes: u8 = 0,
    failures_remaining: u8 = 0,

    fn fill(self: *TestEntropy, buffer: []u8) SecureError!void {
        if (self.failures_remaining != 0) {
            self.failures_remaining -= 1;
            return error.Unavailable;
        }
        self.successes += 1;
        for (buffer, 0..) |*byte, index| {
            byte.* = self.successes +% @as(u8, @truncate(index));
        }
    }
};

threadlocal var csprng_u16_stream: CsprngU16Stream = .{};
const system_entropy: SystemEntropy = .{};

pub fn secureBytes(buffer: []u8) SecureError!void {
    switch (builtin.os.tag) {
        .linux => return linuxSecureBytes(buffer),
        .freestanding, .wasi => return error.Unavailable,
        else => std.Io.Threaded.global_single_threaded.io().randomSecure(buffer) catch
            return error.Unavailable,
    }
}

pub fn seedU64(fallback: u64) u64 {
    var seed: u64 = undefined;
    secureBytes(std.mem.asBytes(&seed)) catch return fallback;
    return seed;
}

pub fn csprngU16() SecureError!u16 {
    const epoch = processEpoch() orelse return freshSecureU16();
    return csprng_u16_stream.next(epoch, &system_entropy);
}

fn freshSecureU16() SecureError!u16 {
    var bytes: [2]u8 = undefined;
    try secureBytes(&bytes);
    return std.mem.readInt(u16, &bytes, .native);
}

fn processEpoch() ?u64 {
    return switch (comptime builtin.os.tag) {
        .linux => @intCast(linux.processId()),
        .windows, .wasi, .freestanding => 0,
        else => posixProcessEpoch(),
    };
}

fn posixProcessEpoch() ?u64 {
    if (comptime !@hasDecl(std.posix.system, "getpid")) return null;
    if (comptime @TypeOf(std.posix.system.getpid) == void) return null;
    return @intCast(std.posix.system.getpid());
}

fn linuxSecureBytes(buffer: []u8) SecureError!void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const rc = linux.getRandom(buffer[filled..]);
        switch (linux.errno(rc)) {
            .success => {
                if (rc == 0) return error.Unavailable;
                filled += rc;
            },
            .intr => {},
            else => return error.Unavailable,
        }
    }
}
