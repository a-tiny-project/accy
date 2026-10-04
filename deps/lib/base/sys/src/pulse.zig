const std = @import("std");
const alloc_phase = @import("alloc_phase");
const builtin = @import("builtin");
const env = @import("env.zig");
const fs = @import("fs.zig");
const net = @import("net.zig");

pub const supported = builtin.os.tag == .linux;

pub const protocol_version: u32 = 32;
const control_channel: u32 = 0xFFFF_FFFF;
const invalid_index: u32 = 0xFFFF_FFFF;
const cookie_length = 256;
const frame_header_length = 20;
const tagged_u32_bytes = 5;
const tagged_arbitrary_overhead_bytes = 5;
const tagged_string_overhead_bytes = 2;
const property_list_overhead_bytes = 2;
const property_entry_overhead_bytes = 13;
const client_name_key = "application.name";
const media_name_key = "media.name";
const media_name_value = "sdfii";
const auth_payload_bytes = 3 * tagged_u32_bytes + tagged_arbitrary_overhead_bytes + cookie_length;
const drain_payload_bytes = 3 * tagged_u32_bytes;

const command_error: u32 = 0;
const command_reply: u32 = 2;
const command_create_playback_stream: u32 = 3;
const command_drain_playback_stream: u32 = 4;
const command_auth: u32 = 8;
const command_set_client_name: u32 = 9;
const command_request: u32 = 61;

pub const sample_format_s16le: u8 = 3;
pub const sample_format_float32le: u8 = 5;

pub const Error = error{
    UnsupportedPlatform,
    MissingRuntimeDirectory,
    ConnectionFailed,
    AuthenticationFailed,
    CapacityOverflow,
    ChannelLimitExceeded,
    ClientNameLimitExceeded,
    ProtocolError,
    ControlPayloadCapacityExceeded,
    ServerError,
    StreamRejected,
    OutOfMemory,
};

pub const Limits = struct {
    inbound_control_payload_bytes: usize = 64 * 1024,
    client_name_bytes: usize = 255,
    channels: u8 = 2,
};

fn clientNamePayloadBytes(name_bytes: usize) error{CapacityOverflow}!usize {
    const fixed_bytes = 2 * tagged_u32_bytes +
        property_list_overhead_bytes + client_name_key.len + property_entry_overhead_bytes;
    return std.math.add(usize, fixed_bytes, name_bytes) catch error.CapacityOverflow;
}

fn streamPayloadBytes(channels: u8) usize {
    return 101 + @as(usize, channels) * 5;
}

pub const Capacity = struct {
    inbound_control_payload_bytes: usize,
    auth_payload_bytes: usize,
    client_name_payload_bytes: usize,
    stream_payload_bytes: usize,
    drain_payload_bytes: usize,
    outbound_control_payload_bytes: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
        if (limits.inbound_control_payload_bytes > std.math.maxInt(u32)) {
            return error.CapacityOverflow;
        }
        if (limits.client_name_bytes >= std.math.maxInt(u32)) {
            return error.CapacityOverflow;
        }
        const client_name_payload_bytes = try clientNamePayloadBytes(limits.client_name_bytes);
        if (client_name_payload_bytes > std.math.maxInt(u32)) return error.CapacityOverflow;
        const stream_payload_bytes = streamPayloadBytes(limits.channels);
        const outbound_control_payload_bytes = @max(
            @max(auth_payload_bytes, client_name_payload_bytes),
            @max(stream_payload_bytes, drain_payload_bytes),
        );
        return .{
            .inbound_control_payload_bytes = limits.inbound_control_payload_bytes,
            .auth_payload_bytes = auth_payload_bytes,
            .client_name_payload_bytes = client_name_payload_bytes,
            .stream_payload_bytes = stream_payload_bytes,
            .drain_payload_bytes = drain_payload_bytes,
            .outbound_control_payload_bytes = outbound_control_payload_bytes,
            .storage_bytes = @max(
                limits.inbound_control_payload_bytes,
                outbound_control_payload_bytes,
            ),
        };
    }
};

const ControlLimits = Limits;
const ControlCapacity = Capacity;

pub const ControlStorage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: ControlCapacity,
    bytes: []u8,

    pub const Limits: type = ControlLimits;
    pub const Capacity: type = ControlCapacity;
    pub const Exhaustion = error{ControlPayloadCapacityExceeded};
    pub const InitError = std.mem.Allocator.Error || error{CapacityOverflow};

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "sys.pulse_control_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "one_reusable_pulseaudio_control_payload_region",
                        .lifetime = .steady,
                        .detail = "one reusable PulseAudio control payload region",
                    },
                },
                .excluded = &.{
                    "socket and kernel buffers, stream handles, and PulseAudio server state",
                    "caller-owned PCM frames and fixed frame-header stack values",
                    "process environment, cookie file handle, and fixed cookie stack bytes",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(ControlLimits, "inbound_control_payload_bytes", "inbound_control_payload_bytes"),
                    alloc_phase.capacity.bindInput(ControlLimits, "client_name_bytes", "client_name_bytes"),
                    alloc_phase.capacity.bindInput(ControlLimits, "channels", "channels"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .literal = 4 } } },
                    .{ .add = .{ .left = 1, .right = 3 } },
                    .{ .maximum = .{ .left = 0, .right = 4 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 5,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "oversize payloads reject before reusable bytes mutate",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "playback control traverses separate stream and environment owners",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "control I/O enters socket, kernel, and PulseAudio server storage",
                },
            },
            .obligations = &.{
                .{ .key = "sys_pulse_control_capacity", .role = .capacity_model },
                .{ .key = "sys_pulse_control_oom_retry", .role = .custom },
                .{ .key = "sys_pulse_control_sealed", .role = .overload },
                .{ .key = "sys_pulse_control_semantics", .role = .custom },
                .{ .key = "sys_pulse_control_drain", .role = .custom },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(allocator: std.mem.Allocator, limits: ControlLimits) InitError!ControlStorage {
        const capacity = try ControlCapacity.derive(limits);
        const bytes = if (capacity.storage_bytes == 0)
            @as([]u8, &.{})
        else
            try allocator.alloc(u8, capacity.storage_bytes);
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .bytes = bytes,
        };
    }

    pub fn activate(self: *ControlStorage) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .steady;
    }

    pub fn inbound(self: *ControlStorage, length: usize) Exhaustion![]u8 {
        std.debug.assert(self.phase != .teardown);
        if (length > self.capacity.inbound_control_payload_bytes) {
            return error.ControlPayloadCapacityExceeded;
        }
        return self.bytes[0..length];
    }

    pub fn outbound(self: *ControlStorage, length: usize) Exhaustion![]u8 {
        std.debug.assert(self.phase != .teardown);
        if (length > self.capacity.outbound_control_payload_bytes) {
            return error.ControlPayloadCapacityExceeded;
        }
        return self.bytes[0..length];
    }

    pub fn deinit(self: *ControlStorage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        if (self.bytes.len != 0) allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(ControlStorage);
}

pub const Spec = struct {
    format: u8 = sample_format_s16le,
    channels: u8 = 2,
    rate: u32 = 48_000,

    pub fn frameBytes(self: Spec) u32 {
        const sample: u32 = switch (self.format) {
            sample_format_s16le => 2,
            sample_format_float32le => 4,
            else => 2,
        };
        return sample * self.channels;
    }
};

pub const TagWriter = struct {
    bytes: []u8,
    index: usize = 0,

    pub const EncodeError = error{ OutputTooSmall, ValueTooLarge };

    pub fn init(bytes: []u8) TagWriter {
        return .{ .bytes = bytes };
    }

    pub fn written(self: *const TagWriter) []const u8 {
        return self.bytes[0..self.index];
    }

    pub fn u32v(self: *TagWriter, value: u32) EncodeError!void {
        const target = try self.take(tagged_u32_bytes);
        target[0] = 'L';
        std.mem.writeInt(u32, target[1..5], value, .big);
    }

    pub fn u8v(self: *TagWriter, value: u8) EncodeError!void {
        const target = try self.take(2);
        target[0] = 'B';
        target[1] = value;
    }

    pub fn boolean(self: *TagWriter, value: bool) EncodeError!void {
        const target = try self.take(1);
        target[0] = if (value) '1' else '0';
    }

    pub fn string(self: *TagWriter, value: ?[]const u8) EncodeError!void {
        if (value) |text| {
            const length = std.math.add(usize, text.len, tagged_string_overhead_bytes) catch {
                return error.ValueTooLarge;
            };
            const target = try self.take(length);
            target[0] = 't';
            @memcpy(target[1..][0..text.len], text);
            target[target.len - 1] = 0;
        } else {
            const target = try self.take(1);
            target[0] = 'N';
        }
    }

    pub fn arbitrary(self: *TagWriter, bytes: []const u8) EncodeError!void {
        if (bytes.len > std.math.maxInt(u32)) return error.ValueTooLarge;
        const length = std.math.add(usize, bytes.len, tagged_arbitrary_overhead_bytes) catch {
            return error.ValueTooLarge;
        };
        const target = try self.take(length);
        target[0] = 'x';
        std.mem.writeInt(u32, target[1..5], @intCast(bytes.len), .big);
        @memcpy(target[5..], bytes);
    }

    pub fn sampleSpec(self: *TagWriter, spec: Spec) EncodeError!void {
        const target = try self.take(7);
        target[0] = 'a';
        target[1] = spec.format;
        target[2] = spec.channels;
        std.mem.writeInt(u32, target[3..7], spec.rate, .big);
    }

    pub fn channelMap(self: *TagWriter, channels: u8) EncodeError!void {
        const target = try self.take(@as(usize, channels) + 2);
        target[0] = 'm';
        target[1] = channels;
        var index: u8 = 0;
        while (index < channels) : (index += 1) {
            const position: u8 = if (channels == 1) 0 else 1 + index;
            target[2 + @as(usize, index)] = position;
        }
    }

    pub fn cvolume(self: *TagWriter, channels: u8, volume: u32) EncodeError!void {
        const target = try self.take(2 + @as(usize, channels) * 4);
        target[0] = 'v';
        target[1] = channels;
        var index: u8 = 0;
        while (index < channels) : (index += 1) {
            const offset = 2 + @as(usize, index) * 4;
            std.mem.writeInt(u32, target[offset..][0..4], volume, .big);
        }
    }

    pub fn propList(self: *TagWriter, pairs: []const [2][]const u8) EncodeError!void {
        var length: usize = property_list_overhead_bytes;
        for (pairs) |pair| {
            if (pair[1].len >= std.math.maxInt(u32)) return error.ValueTooLarge;
            length = std.math.add(usize, length, pair[0].len) catch return error.ValueTooLarge;
            length = std.math.add(usize, length, pair[1].len) catch return error.ValueTooLarge;
            length = std.math.add(usize, length, property_entry_overhead_bytes) catch {
                return error.ValueTooLarge;
            };
        }
        const target = try self.take(length);
        var writer = TagWriter.init(target);
        (try writer.take(1))[0] = 'P';
        for (pairs) |pair| {
            try writer.string(pair[0]);
            const data_len: u32 = @intCast(pair[1].len + 1);
            try writer.u32v(data_len);
            try writer.propertyValue(pair[1]);
        }
        try writer.string(null);
        std.debug.assert(writer.index == target.len);
    }

    fn propertyValue(self: *TagWriter, value: []const u8) EncodeError!void {
        if (value.len >= std.math.maxInt(u32)) return error.ValueTooLarge;
        const target = try self.take(value.len + 6);
        target[0] = 'x';
        std.mem.writeInt(u32, target[1..5], @intCast(value.len + 1), .big);
        @memcpy(target[5..][0..value.len], value);
        target[target.len - 1] = 0;
    }

    fn take(self: *TagWriter, length: usize) EncodeError![]u8 {
        if (length > self.bytes.len - self.index) return error.OutputTooSmall;
        const target = self.bytes[self.index..][0..length];
        self.index += length;
        return target;
    }
};

pub const TagReader = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn u32v(self: *TagReader) Error!u32 {
        try self.expect('L');
        return self.rawU32();
    }

    pub fn boolean(self: *TagReader) Error!bool {
        if (self.index >= self.bytes.len) return error.ProtocolError;
        const tag = self.bytes[self.index];
        self.index += 1;
        return switch (tag) {
            '1' => true,
            '0' => false,
            else => error.ProtocolError,
        };
    }

    pub fn skipString(self: *TagReader) Error!void {
        if (self.index >= self.bytes.len) return error.ProtocolError;
        const tag = self.bytes[self.index];
        self.index += 1;
        if (tag == 'N') return;
        if (tag != 't') return error.ProtocolError;
        const terminator = std.mem.indexOfScalarPos(u8, self.bytes, self.index, 0) orelse return error.ProtocolError;
        self.index = terminator + 1;
    }

    pub fn sampleSpec(self: *TagReader) Error!Spec {
        try self.expect('a');
        if (self.index + 6 > self.bytes.len) return error.ProtocolError;
        const format = self.bytes[self.index];
        const channels = self.bytes[self.index + 1];
        self.index += 2;
        const rate = try self.rawU32();
        return .{ .format = format, .channels = channels, .rate = rate };
    }

    pub fn skipChannelMap(self: *TagReader) Error!void {
        try self.expect('m');
        if (self.index >= self.bytes.len) return error.ProtocolError;
        const channels = self.bytes[self.index];
        self.index += 1 + @as(usize, channels);
        if (self.index > self.bytes.len) return error.ProtocolError;
    }

    fn expect(self: *TagReader, tag: u8) Error!void {
        if (self.index >= self.bytes.len) return error.ProtocolError;
        if (self.bytes[self.index] != tag) return error.ProtocolError;
        self.index += 1;
    }

    fn rawU32(self: *TagReader) Error!u32 {
        if (self.index + 4 > self.bytes.len) return error.ProtocolError;
        const value = std.mem.readInt(u32, self.bytes[self.index..][0..4], .big);
        self.index += 4;
        return value;
    }
};

pub const StreamInfo = struct {
    channel: u32,
    sink_input: u32,
    missing: u32,
    minreq: u32,
};

pub const Playback = struct {
    stream: net.Stream,
    sequence: u32 = 0,
    info: StreamInfo = .{ .channel = 0, .sink_input = invalid_index, .missing = 0, .minreq = 0 },
    spec: Spec,
    storage: ControlStorage,

    pub const Limits: type = ControlLimits;
    pub const Capacity: type = ControlCapacity;
    pub const Storage: type = ControlStorage;

    pub fn open(
        allocator: std.mem.Allocator,
        limits: ControlLimits,
        spec: Spec,
        name: []const u8,
    ) Error!Playback {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (name.len > limits.client_name_bytes) return error.ClientNameLimitExceeded;
        if (spec.channels > limits.channels) return error.ChannelLimitExceeded;

        var storage = try ControlStorage.init(allocator, limits);
        errdefer storage.deinit(allocator);

        var cookie = @as([cookie_length]u8, @splat(0));
        loadCookie(&cookie);

        var path_buffer: [256]u8 = undefined;
        const path = socketPath(&path_buffer) orelse return error.MissingRuntimeDirectory;
        const address = net.Address.initUnix(path) catch return error.ConnectionFailed;
        var stream = net.connectStream(address) catch return error.ConnectionFailed;
        errdefer stream.close();

        var playback = Playback{
            .stream = stream,
            .spec = spec,
            .storage = storage,
        };

        try playback.authenticate(&cookie);
        try playback.setClientName(name);
        try playback.createStream();
        playback.storage.activate();
        return playback;
    }

    pub fn close(self: *Playback, allocator: std.mem.Allocator) void {
        self.stream.close();
        self.storage.deinit(allocator);
        self.* = undefined;
    }

    fn authenticate(self: *Playback, cookie: *const [cookie_length]u8) Error!void {
        var writer = TagWriter.init(
            self.storage.outbound(self.storage.capacity.auth_payload_bytes) catch unreachable,
        );
        writer.u32v(command_auth) catch unreachable;
        writer.u32v(self.nextSequence()) catch unreachable;
        writer.u32v(protocol_version) catch unreachable;
        writer.arbitrary(cookie) catch unreachable;
        std.debug.assert(writer.written().len == self.storage.capacity.auth_payload_bytes);
        try self.sendControl(writer.written());

        const reply = try self.readReply();
        var reader = TagReader{ .bytes = reply };
        const server_version = try reader.u32v();
        if ((server_version & 0xFFFF) < 13) return error.AuthenticationFailed;
    }

    fn setClientName(self: *Playback, name: []const u8) Error!void {
        const payload_bytes = clientNamePayloadBytes(name.len) catch unreachable;
        var writer = TagWriter.init(self.storage.outbound(payload_bytes) catch unreachable);
        writer.u32v(command_set_client_name) catch unreachable;
        writer.u32v(self.nextSequence()) catch unreachable;
        writer.propList(&.{.{ client_name_key, name }}) catch unreachable;
        std.debug.assert(writer.written().len == payload_bytes);
        try self.sendControl(writer.written());
        _ = try self.readReply();
    }

    fn createStream(self: *Playback) Error!void {
        const bytes_per_second = self.spec.rate * self.spec.frameBytes();
        const target_length = bytes_per_second / 4;

        const payload_bytes = streamPayloadBytes(self.spec.channels);
        var writer = TagWriter.init(self.storage.outbound(payload_bytes) catch unreachable);
        writePlaybackStreamPayload(
            &writer,
            self.nextSequence(),
            self.spec,
            target_length,
        ) catch unreachable;
        std.debug.assert(writer.written().len == payload_bytes);
        try self.sendControl(writer.written());

        const reply = try self.readReply();
        var reader = TagReader{ .bytes = reply };
        self.info.channel = try reader.u32v();
        self.info.sink_input = try reader.u32v();
        self.info.missing = try reader.u32v();
        _ = try reader.u32v();
        const target_reply = try reader.u32v();
        _ = try reader.u32v();
        self.info.minreq = try reader.u32v();
        _ = target_reply;
        if (self.info.sink_input == invalid_index) return error.StreamRejected;
    }

    pub fn writeFrames(self: *Playback, bytes: []const u8) Error!void {
        var remaining = bytes;
        while (remaining.len > 0) {
            if (self.info.missing == 0) {
                try self.pumpUntilRequest();
                continue;
            }
            const chunk_len = @min(remaining.len, self.info.missing);
            try self.sendData(remaining[0..chunk_len]);
            self.info.missing -= @intCast(chunk_len);
            remaining = remaining[chunk_len..];
        }
    }

    pub fn drain(self: *Playback) Error!void {
        var writer = TagWriter.init(
            self.storage.outbound(self.storage.capacity.drain_payload_bytes) catch unreachable,
        );
        writer.u32v(command_drain_playback_stream) catch unreachable;
        writer.u32v(self.nextSequence()) catch unreachable;
        writer.u32v(self.info.channel) catch unreachable;
        std.debug.assert(writer.written().len == self.storage.capacity.drain_payload_bytes);
        try self.sendControl(writer.written());
        _ = try self.readReply();
    }

    fn pumpUntilRequest(self: *Playback) Error!void {
        const message = try self.readControl();
        var reader = TagReader{ .bytes = message };
        const command = try reader.u32v();
        _ = try reader.u32v();
        switch (command) {
            command_request => {
                const channel = try reader.u32v();
                const nbytes = try reader.u32v();
                if (channel == self.info.channel) {
                    self.info.missing += nbytes;
                }
            },
            command_error => return error.ServerError,
            else => {},
        }
    }

    fn sendData(self: *Playback, bytes: []const u8) Error!void {
        var header: [frame_header_length]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(bytes.len), .big);
        std.mem.writeInt(u32, header[4..8], self.info.channel, .big);
        std.mem.writeInt(u32, header[8..12], 0, .big);
        std.mem.writeInt(u32, header[12..16], 0, .big);
        std.mem.writeInt(u32, header[16..20], 0, .big);
        self.stream.writeAll(&header) catch return error.ConnectionFailed;
        self.stream.writeAll(bytes) catch return error.ConnectionFailed;
    }

    fn sendControl(self: *Playback, payload: []const u8) Error!void {
        var header: [frame_header_length]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(payload.len), .big);
        std.mem.writeInt(u32, header[4..8], control_channel, .big);
        std.mem.writeInt(u32, header[8..12], 0, .big);
        std.mem.writeInt(u32, header[12..16], 0, .big);
        std.mem.writeInt(u32, header[16..20], 0, .big);
        self.stream.writeAll(&header) catch return error.ConnectionFailed;
        self.stream.writeAll(payload) catch return error.ConnectionFailed;
    }

    fn readReply(self: *Playback) Error![]const u8 {
        while (true) {
            const message = try self.readControl();
            var reader = TagReader{ .bytes = message };
            const command = try reader.u32v();
            _ = try reader.u32v();
            switch (command) {
                command_reply => return message[reader.index..],
                command_error => return error.ServerError,
                command_request => {
                    const channel = try reader.u32v();
                    const nbytes = try reader.u32v();
                    if (channel == self.info.channel) {
                        self.info.missing += nbytes;
                    }
                },
                else => {},
            }
        }
    }

    fn readControl(self: *Playback) Error![]const u8 {
        while (true) {
            var header: [frame_header_length]u8 = undefined;
            try self.readExact(&header);
            const length = std.mem.readInt(u32, header[0..4], .big);
            const channel = std.mem.readInt(u32, header[4..8], .big);
            const target = self.storage.inbound(length) catch |err| {
                try self.discardExact(length, &header);
                return err;
            };
            try self.readExact(target);
            if (channel == control_channel) return target;
        }
    }

    fn discardExact(
        self: *Playback,
        length: usize,
        scratch: *[frame_header_length]u8,
    ) Error!void {
        var remaining = length;
        while (remaining > 0) {
            const chunk_bytes = @min(remaining, scratch.len);
            try self.readExact(scratch[0..chunk_bytes]);
            remaining -= chunk_bytes;
        }
    }

    fn readExact(self: *Playback, buffer: []u8) Error!void {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const count = self.stream.read(buffer[filled..]) catch return error.ConnectionFailed;
            if (count == 0) return error.ConnectionFailed;
            filled += count;
        }
    }

    fn nextSequence(self: *Playback) u32 {
        const value = self.sequence;
        self.sequence += 1;
        return value;
    }
};

fn writePlaybackStreamPayload(
    writer: *TagWriter,
    sequence: u32,
    spec: Spec,
    target: u32,
) TagWriter.EncodeError!void {
    try writer.u32v(command_create_playback_stream);
    try writer.u32v(sequence);
    try writer.sampleSpec(spec);
    try writer.channelMap(spec.channels);
    try writer.u32v(invalid_index);
    try writer.string(null);
    try writer.u32v(target * 4);
    try writer.boolean(false);
    try writer.u32v(target);
    try writer.u32v(target / 2);
    try writer.u32v(spec.frameBytes() * 256);
    try writer.u32v(0);
    try writer.cvolume(spec.channels, 0x10000);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(true);
    try writer.propList(&.{.{ media_name_key, media_name_value }});
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.boolean(false);
    try writer.u8v(0);
}

pub fn available() bool {
    if (comptime !supported) return false;
    var path_buffer: [256]u8 = undefined;
    const path = socketPath(&path_buffer) orelse return false;
    const address = net.Address.initUnix(path) catch return false;
    var probe = net.connectStream(address) catch return false;
    probe.close();
    return true;
}

fn socketPath(buffer: []u8) ?[]const u8 {
    if (env.get("PULSE_SERVER")) |server| {
        if (std.mem.startsWith(u8, server, "unix:")) {
            const path = server[5..];
            if (path.len == 0 or path.len > buffer.len) return null;
            @memcpy(buffer[0..path.len], path);
            return buffer[0..path.len];
        }
        return null;
    }
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/pulse/native", .{runtime}) catch null;
}

fn loadCookie(cookie: *[cookie_length]u8) void {
    var path_buffer: [512]u8 = undefined;
    const home = env.get("HOME") orelse return;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/.config/pulse/cookie", .{home}) catch return;
    const file = fs.openAbsoluteFile(path, .{}) catch return;
    defer fs.closeHandle(file);
    var filled: usize = 0;
    while (filled < cookie.len) {
        const count = fs.readHandle(file, cookie[filled..]) catch return;
        if (count == 0) return;
        filled += count;
    }
}

test "pulse fixed tag writer preserves control encoding semantics" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlStorage, "sys_pulse_control_semantics"),
        );
    }

    var payload: [auth_payload_bytes]u8 = undefined;
    var writer = TagWriter.init(&payload);
    try writer.u32v(command_auth);
    try writer.u32v(1);
    try writer.u32v(protocol_version);
    const cookie = @as([cookie_length]u8, @splat(0xAB));
    try writer.arbitrary(&cookie);
    const written = writer.written();

    try std.testing.expectEqual(@as(u8, 'L'), written[0]);
    try std.testing.expectEqual(@as(usize, auth_payload_bytes), written.len);

    var reader = TagReader{ .bytes = written };
    try std.testing.expectEqual(command_auth, try reader.u32v());
    try std.testing.expectEqual(@as(u32, 1), try reader.u32v());
    try std.testing.expectEqual(protocol_version, try reader.u32v());
}

test "sample spec and strings round-trip" {
    var payload: [64]u8 = undefined;
    var writer = TagWriter.init(&payload);
    const spec = Spec{ .format = sample_format_s16le, .channels = 2, .rate = 48_000 };
    try writer.sampleSpec(spec);
    try writer.string("sdfii");
    try writer.string(null);
    try writer.channelMap(2);
    const written = writer.written();

    var reader = TagReader{ .bytes = written };
    const decoded = try reader.sampleSpec();
    try std.testing.expectEqual(spec.format, decoded.format);
    try std.testing.expectEqual(spec.channels, decoded.channels);
    try std.testing.expectEqual(spec.rate, decoded.rate);
    try reader.skipString();
    try reader.skipString();
    try reader.skipChannelMap();
    try std.testing.expectEqual(written.len, reader.index);
}

fn independentlyEncodedCapacity(
    name: []const u8,
    inbound_control_payload_bytes: usize,
    channels: u8,
) !Capacity {
    var payload: [8192]u8 = undefined;
    var writer = TagWriter.init(&payload);
    try writer.u32v(command_auth);
    try writer.u32v(0);
    try writer.u32v(protocol_version);
    const cookie = @as([cookie_length]u8, @splat(0));
    try writer.arbitrary(&cookie);
    const encoded_auth_payload_bytes = writer.written().len;

    writer = TagWriter.init(&payload);
    try writer.u32v(command_set_client_name);
    try writer.u32v(0);
    try writer.propList(&.{.{ client_name_key, name }});
    const encoded_client_name_payload_bytes = writer.written().len;

    writer = TagWriter.init(&payload);
    try writePlaybackStreamPayload(&writer, 0, .{ .channels = channels }, 1024);
    const encoded_stream_payload_bytes = writer.written().len;

    writer = TagWriter.init(&payload);
    try writer.u32v(command_drain_playback_stream);
    try writer.u32v(0);
    try writer.u32v(0);
    const encoded_drain_payload_bytes = writer.written().len;
    const outbound_control_payload_bytes = @max(
        @max(encoded_auth_payload_bytes, encoded_client_name_payload_bytes),
        @max(encoded_stream_payload_bytes, encoded_drain_payload_bytes),
    );
    return .{
        .inbound_control_payload_bytes = inbound_control_payload_bytes,
        .auth_payload_bytes = encoded_auth_payload_bytes,
        .client_name_payload_bytes = encoded_client_name_payload_bytes,
        .stream_payload_bytes = encoded_stream_payload_bytes,
        .drain_payload_bytes = encoded_drain_payload_bytes,
        .outbound_control_payload_bytes = outbound_control_payload_bytes,
        .storage_bytes = @max(
            inbound_control_payload_bytes,
            outbound_control_payload_bytes,
        ),
    };
}

test "pulse control capacity matches independently encoded payload maxima" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlStorage, "sys_pulse_control_capacity"),
        );
    }

    var name: [4096]u8 = undefined;
    @memset(&name, 'n');

    for (0..name.len + 1) |name_bytes| {
        const channels: u8 = @intCast(name_bytes % 256);
        const inbound_control_payload_bytes = name_bytes / 2;
        try std.testing.expectEqual(
            try independentlyEncodedCapacity(
                name[0..name_bytes],
                inbound_control_payload_bytes,
                channels,
            ),
            try Capacity.derive(.{
                .inbound_control_payload_bytes = inbound_control_payload_bytes,
                .client_name_bytes = name_bytes,
                .channels = channels,
            }),
        );
    }

    const client_name_base_bytes = try clientNamePayloadBytes(0);
    const maximum_client_name_bytes = @as(usize, std.math.maxInt(u32)) -
        client_name_base_bytes;
    _ = try Capacity.derive(.{
        .inbound_control_payload_bytes = std.math.maxInt(u32),
        .client_name_bytes = maximum_client_name_bytes,
        .channels = std.math.maxInt(u8),
    });
    try std.testing.expectError(
        error.CapacityOverflow,
        Capacity.derive(.{ .client_name_bytes = maximum_client_name_bytes + 1 }),
    );
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try std.testing.expectError(
            error.CapacityOverflow,
            Capacity.derive(.{
                .inbound_control_payload_bytes = @as(usize, std.math.maxInt(u32)) + 1,
            }),
        );
    }
}

fn checkControlStorageInitFailures(allocator: std.mem.Allocator) !void {
    var storage = try ControlStorage.init(allocator, .{
        .inbound_control_payload_bytes = 4096,
        .client_name_bytes = 32,
        .channels = 8,
    });
    storage.deinit(allocator);
}

test "pulse control storage retries after allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlStorage, "sys_pulse_control_oom_retry"),
        );
    }

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkControlStorageInitFailures,
        .{},
    );

    var storage = try ControlStorage.init(std.testing.allocator, .{
        .inbound_control_payload_bytes = 4096,
        .client_name_bytes = 32,
        .channels = 8,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    try std.testing.expectEqual(alloc_phase.capacity.Phase.steady, storage.phase);
}

test "pulse control storage is sealed before encoding and boundary rejection" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlStorage, "sys_pulse_control_sealed"),
        );
    }

    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
    var storage = ControlStorage.init(
        phase_allocator.initializationAllocator(),
        .{
            .inbound_control_payload_bytes = 32,
            .client_name_bytes = 8,
            .channels = 2,
        },
    ) catch |err| {
        phase_allocator.abortInitialization();
        phase_allocator.deinit();
        return err;
    };
    defer {
        if (phase_allocator.phase() == .initialization) phase_allocator.abortInitialization();
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (storage.phase != .teardown) storage.deinit(phase_allocator.teardownAllocator());
        phase_allocator.deinit();
    }

    const pointer = storage.bytes.ptr;
    const capacity = storage.capacity;
    @memset(storage.bytes, 0xa5);
    phase_allocator.seal();
    storage.activate();

    try std.testing.expectError(
        error.ControlPayloadCapacityExceeded,
        storage.inbound(storage.capacity.inbound_control_payload_bytes + 1),
    );
    try std.testing.expectError(
        error.ControlPayloadCapacityExceeded,
        storage.outbound(storage.capacity.outbound_control_payload_bytes + 1),
    );
    for (storage.bytes) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);

    var writer = TagWriter.init(
        try storage.outbound(storage.capacity.auth_payload_bytes),
    );
    try writer.u32v(command_auth);
    try writer.u32v(0);
    try writer.u32v(protocol_version);
    const cookie = @as([cookie_length]u8, @splat(0));
    try writer.arbitrary(&cookie);
    try std.testing.expectEqual(storage.capacity.auth_payload_bytes, writer.written().len);
    try std.testing.expect(storage.bytes.ptr == pointer);
    try std.testing.expectEqual(capacity, storage.capacity);

    var short = @as([(tagged_u32_bytes - 1)]u8, @splat(0xa5));
    var short_writer = TagWriter.init(&short);
    try std.testing.expectError(error.OutputTooSmall, short_writer.u32v(1));
    try std.testing.expectEqual(@as(usize, 0), short_writer.written().len);
    for (short) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

test "pulse playback rejects root limits before allocation or connection effects" {
    if (comptime !supported) return error.SkipZigTest;

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.ClientNameLimitExceeded,
        Playback.open(
            failing.allocator(),
            .{ .client_name_bytes = 3 },
            .{},
            "four",
        ),
    );
    try std.testing.expectError(
        error.ChannelLimitExceeded,
        Playback.open(
            failing.allocator(),
            .{ .channels = 1 },
            .{ .channels = 2 },
            "",
        ),
    );
    const maximum_client_name_bytes = @as(usize, std.math.maxInt(u32)) -
        (try clientNamePayloadBytes(0));
    try std.testing.expectError(
        error.CapacityOverflow,
        Playback.open(
            failing.allocator(),
            .{ .client_name_bytes = maximum_client_name_bytes + 1 },
            .{},
            "",
        ),
    );
}

fn writeTestFrame(peer: net.Stream, channel: u32, payload: []const u8) !void {
    var header = @as([frame_header_length]u8, @splat(0));
    std.mem.writeInt(u32, header[0..4], @intCast(payload.len), .big);
    std.mem.writeInt(u32, header[4..8], channel, .big);
    try peer.writeAll(&header);
    try peer.writeAll(payload);
}

fn writeTestReply(peer: net.Stream) !void {
    var payload: [2 * tagged_u32_bytes]u8 = undefined;
    var writer = TagWriter.init(&payload);
    try writer.u32v(command_reply);
    try writer.u32v(0);
    try writeTestFrame(peer, control_channel, &payload);
}

test "pulse playback drains through sealed control storage" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlStorage, "sys_pulse_control_drain"),
        );
    }

    if (comptime !supported) return error.SkipZigTest;

    const sockets = try net.socketPairUnixStream();
    var peer = net.Stream.initFd(sockets[1]);
    defer peer.close();
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
    const storage = ControlStorage.init(
        phase_allocator.initializationAllocator(),
        .{
            .inbound_control_payload_bytes = 32,
            .client_name_bytes = 8,
            .channels = 2,
        },
    ) catch |err| {
        net.close(sockets[0]);
        phase_allocator.abortInitialization();
        phase_allocator.deinit();
        return err;
    };
    var playback = Playback{
        .stream = net.Stream.initFd(sockets[0]),
        .info = .{ .channel = 7, .sink_input = 0, .missing = 0, .minreq = 0 },
        .spec = .{},
        .storage = storage,
    };
    defer {
        if (phase_allocator.phase() == .initialization) phase_allocator.abortInitialization();
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (playback.storage.phase != .teardown) {
            playback.close(phase_allocator.teardownAllocator());
        }
        phase_allocator.deinit();
    }

    const oversized = @as([33]u8, @splat(0x5a));
    try writeTestFrame(peer, control_channel, &oversized);
    try writeTestReply(peer);

    const pointer = playback.storage.bytes.ptr;
    const capacity = playback.storage.capacity;
    @memset(playback.storage.bytes, 0xa5);
    phase_allocator.seal();
    playback.storage.activate();
    try std.testing.expectError(error.ControlPayloadCapacityExceeded, playback.readControl());
    for (playback.storage.bytes) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    try playback.drain();

    var request: [frame_header_length + drain_payload_bytes]u8 = undefined;
    var received: usize = 0;
    while (received < request.len) {
        const count = try peer.read(request[received..]);
        if (count == 0) return error.ConnectionFailed;
        received += count;
    }
    try std.testing.expectEqual(
        @as(u32, drain_payload_bytes),
        std.mem.readInt(u32, request[0..4], .big),
    );
    try std.testing.expectEqual(
        control_channel,
        std.mem.readInt(u32, request[4..8], .big),
    );
    var reader = TagReader{ .bytes = request[frame_header_length..] };
    try std.testing.expectEqual(command_drain_playback_stream, try reader.u32v());
    try std.testing.expectEqual(@as(u32, 0), try reader.u32v());
    try std.testing.expectEqual(@as(u32, 7), try reader.u32v());
    try std.testing.expect(playback.storage.bytes.ptr == pointer);
    try std.testing.expectEqual(capacity, playback.storage.capacity);
}

test "spec frame bytes follow format and channels" {
    try std.testing.expectEqual(@as(u32, 4), (Spec{ .format = sample_format_s16le, .channels = 2 }).frameBytes());
    try std.testing.expectEqual(@as(u32, 8), (Spec{ .format = sample_format_float32le, .channels = 2 }).frameBytes());
}

test "live playback reaches the pulse server" {
    if (comptime !supported) return error.SkipZigTest;
    if (!available()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const spec = Spec{ .format = sample_format_s16le, .channels = 2, .rate = 48_000 };
    var playback = Playback.open(allocator, .{
        .client_name_bytes = "sys-pulse-live-test".len,
        .channels = spec.channels,
    }, spec, "sys-pulse-live-test") catch |err| switch (err) {
        error.MissingRuntimeDirectory, error.ConnectionFailed => return error.SkipZigTest,
        else => return err,
    };
    defer playback.close(allocator);

    try std.testing.expect(playback.info.sink_input != invalid_index);
    try std.testing.expect(playback.info.missing > 0);

    const duration_ms: u32 = blk: {
        const raw = env.get("TINY_PULSE_LIVE_MS") orelse break :blk 100;
        break :blk std.fmt.parseInt(u32, raw, 10) catch 100;
    };
    const frame_count = spec.rate * duration_ms / 1000;
    const bytes = try allocator.alloc(u8, frame_count * spec.frameBytes());
    defer allocator.free(bytes);
    var index: usize = 0;
    while (index < frame_count) : (index += 1) {
        const phase = @as(f32, @floatFromInt(index)) / 48_000.0;
        const sample: i16 = @intFromFloat(@sin(phase * 2.0 * std.math.pi * 440.0) * 8000.0);
        std.mem.writeInt(i16, bytes[index * 4 ..][0..2], sample, .little);
        std.mem.writeInt(i16, bytes[index * 4 + 2 ..][0..2], sample, .little);
    }
    try playback.writeFrames(bytes);
    try playback.drain();
}
