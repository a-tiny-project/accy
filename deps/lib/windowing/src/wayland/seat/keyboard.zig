const std = @import("std");
const alloc_phase = @import("alloc_phase");
const builtin = @import("builtin");
const sys = @import("sys");
const native = @import("wayland");
const native_xkb = @import("xkb");
const windowing = @import("../../root.zig");

const core = native.protocol.core;
const runtime = native.runtime;

pub const KeyAction = struct {
    key: windowing.Key,
    evdev_code: u32,
    pressed: bool,
    modifiers: windowing.Modifier,
    repeated: bool = false,
    emit_event: bool = true,
};

pub const FocusFn = *const fn (context: *anyopaque, focused: bool) void;
pub const KeyFn = *const fn (context: *anyopaque, action: KeyAction) void;
pub const TextFn = *const fn (context: *anyopaque, bytes: []const u8, modifiers: windowing.Modifier) void;

pub const Callbacks = struct {
    context: *anyopaque,
    focus: FocusFn,
    key: KeyFn,
    text: TextFn,
};

pub const ComposeLimits = native_xkb.compose.Limits;
pub const ComposeScratchLimits = native_xkb.compose.ScratchLimits;

pub const Options = struct {
    locale: ?[]const u8 = null,
    compose_file: ?[]const u8 = null,
    compose_limits: ComposeLimits,
    compose_scratch_limits: ComposeScratchLimits,
};

pub const RepeatMetadata = struct {
    evdev_code: u32,
    rate_hz: u32,
    delay_ms: u32,
    tick: u64,
    deadline_ms: u32,
};

pub const InitError = native_xkb.compose.Storage.InitError ||
    native_xkb.compose.ScratchStorage.InitError || native_xkb.compose.LoadError;

const AttachPlatformError = error{
    UnsupportedKeymapFormat,
    InvalidKeymap,
};

pub const AttachError = sys.memory.MapError || native_xkb.keymap.text.Error || AttachPlatformError;

const RuntimePlatformError = error{
    InvalidKeyboardEvent,
    InvalidRepeatInfo,
    MissingKeymap,
};

pub const RuntimeError = AttachError || RuntimePlatformError;

pub const Keyboard = struct {
    allocator: std.mem.Allocator,
    callbacks: Callbacks,
    compose_storage: native_xkb.compose.Storage,
    compose_table: native_xkb.compose.Table,
    compose_state: native_xkb.compose.State,
    keymap: ?native_xkb.keymap.text.Compiled = null,
    state: ?native_xkb.state.State = null,
    mapping_state: ?native_xkb.state.State = null,
    surface: ?u32 = null,
    pressed: PressedKeys = .{},
    repeat: RepeatState = .{},
    focused: bool = false,
    failure: ?RuntimeError = null,

    pub fn init(allocator: std.mem.Allocator, callbacks: Callbacks, options: Options) InitError!Keyboard {
        var compose_storage = try native_xkb.compose.Storage.init(
            allocator,
            options.compose_limits,
        );
        errdefer compose_storage.deinit(allocator);
        var compose_scratch = try native_xkb.compose.ScratchStorage.init(
            allocator,
            options.compose_scratch_limits,
        );
        defer compose_scratch.deinit(allocator);
        compose_storage.activate();
        compose_scratch.activate();
        const compose_table = try native_xkb.compose.load(&compose_storage, &compose_scratch, .{
            .locale = options.locale orelse processLocale(),
            .home = sys.env.getConstant("HOME"),
            .xcompose_file = options.compose_file orelse sys.env.getConstant("XCOMPOSEFILE"),
            .xdg_config_home = sys.env.getConstant("XDG_CONFIG_HOME"),
            .system_directory = sys.env.getConstant("XLOCALEDIR") orelse
                native_xkb.compose.default_system_directory,
        });
        errdefer compose_storage.reset();
        const compose_state = native_xkb.compose.State.init(&compose_table);

        return .{
            .allocator = allocator,
            .callbacks = callbacks,
            .compose_storage = compose_storage,
            .compose_table = compose_table,
            .compose_state = compose_state,
        };
    }

    pub fn deinit(self: *Keyboard) void {
        self.releaseKeymap();
        self.compose_storage.reset();
        self.compose_storage.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setSurface(self: *Keyboard, surface: ?u32) void {
        self.surface = surface;
    }

    pub fn attachKeymapFd(
        self: *Keyboard,
        format: u32,
        descriptor: sys.fd.Descriptor,
        size: u32,
    ) AttachError!void {
        defer sys.fd.close(descriptor);

        if (format != keymap_format_xkb_v1) return error.UnsupportedKeymapFormat;
        if (size == 0) return error.InvalidKeymap;

        const byte_count = std.math.cast(usize, size) orelse return error.InvalidKeymap;
        const mapping = try sys.memory.mapPrivateFile(descriptor, byte_count, .{ .read = true }, 0);
        defer sys.memory.unmap(mapping);

        if (mapping[byte_count - 1] != 0) return error.InvalidKeymap;
        const text = mapping[0 .. byte_count - 1];

        var next_keymap = try native_xkb.keymap.text.compile(self.allocator, text);
        errdefer next_keymap.deinit();
        const next_state = native_xkb.state.State.init(next_keymap.keymap());
        const next_mapping_state = native_xkb.state.State.init(next_keymap.keymap());

        self.repeat.cancel();
        self.compose_state.reset();
        self.releasePressed(false);
        self.releaseKeymap();
        self.keymap = next_keymap;
        self.state = next_state;
        self.mapping_state = next_mapping_state;
    }

    pub fn repeatMetadata(self: *const Keyboard) ?RepeatMetadata {
        return self.repeat.metadata();
    }

    pub fn clearFocus(self: *Keyboard) void {
        const was_focused = self.focused;
        self.focused = false;
        self.repeat.cancel();
        self.compose_state.reset();
        self.releasePressed(false);
        if (was_focused) self.callbacks.focus(self.callbacks.context, false);
    }

    pub fn dispatchRepeat(self: *Keyboard, now_ms: u32) RuntimeError!bool {
        const evdev_code = self.repeat.consume(now_ms) orelse return false;
        try self.emitPress(evdev_code, true);
        return true;
    }

    pub fn takeFailure(self: *Keyboard) ?RuntimeError {
        const result = self.failure;
        self.failure = null;
        return result;
    }

    pub fn modifiers(self: *const Keyboard) windowing.Modifier {
        var result = self.pressed.modifiers();
        const state = if (self.state) |*value| value else return result;
        result.shift = result.shift or state.modifierActive("Shift");
        result.ctrl = result.ctrl or state.modifierActive("Control");
        result.alt = result.alt or state.modifierActive("Mod1");
        result.super = result.super or state.modifierActive("Mod4");
        return result;
    }

    pub fn dispatch(self: *Keyboard, event: *runtime.RoutedView) !void {
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            core.wl_keyboard.events.keymap.opcode => {
                const format = try decoder.unsigned();
                _ = try decoder.descriptor();
                const size = try decoder.unsigned();
                try decoder.finish();
                const descriptor = try event.takeDescriptor(0);
                self.attachKeymapFd(format, descriptor, size) catch |failure| self.recordFailure(failure);
            },
            core.wl_keyboard.events.enter.opcode => {
                _ = try decoder.unsigned();
                const surface = (try decoder.object()).raw;
                const keys = try decoder.array();
                try decoder.finish();
                self.enter(surface, keys) catch |failure| self.recordFailure(failure);
            },
            core.wl_keyboard.events.leave.opcode => {
                _ = try decoder.unsigned();
                const surface = (try decoder.object()).raw;
                try decoder.finish();
                self.leave(surface);
            },
            core.wl_keyboard.events.key.opcode => {
                _ = try decoder.unsigned();
                const time = try decoder.unsigned();
                const key_value = try decoder.unsigned();
                const state_value = try decoder.unsigned();
                try decoder.finish();
                self.key(time, key_value, state_value) catch |failure| self.recordFailure(failure);
            },
            core.wl_keyboard.events.modifiers.opcode => {
                _ = try decoder.unsigned();
                const depressed = try decoder.unsigned();
                const latched = try decoder.unsigned();
                const locked = try decoder.unsigned();
                const group = try decoder.unsigned();
                try decoder.finish();
                self.updateModifiers(depressed, latched, locked, group) catch |failure| self.recordFailure(failure);
            },
            core.wl_keyboard.events.repeat_info.opcode => {
                const rate = try decoder.signed();
                const delay = try decoder.signed();
                try decoder.finish();
                self.repeatInfo(rate, delay) catch |failure| self.recordFailure(failure);
            },
            else => self.recordFailure(error.InvalidKeyboardEvent),
        }
    }

    fn releaseKeymap(self: *Keyboard) void {
        self.state = null;
        self.mapping_state = null;
        if (self.keymap) |*keymap| keymap.deinit();
        self.keymap = null;
    }

    fn enter(self: *Keyboard, surface: u32, raw_keys: []const u8) RuntimeError!void {
        if (!self.matchesSurface(surface)) return;
        if (raw_keys.len % @sizeOf(u32) != 0) return error.InvalidKeyboardEvent;

        self.focused = true;
        self.releasePressed(false);

        var offset: usize = 0;
        while (offset < raw_keys.len) : (offset += @sizeOf(u32)) {
            const evdev_code = std.mem.readInt(u32, raw_keys[offset..][0..4], builtin.cpu.arch.endian());
            const mapped = try self.mappedKey(evdev_code);
            self.pressed.put(evdev_code, mapped);
            self.callbacks.key(self.callbacks.context, .{
                .key = mapped,
                .evdev_code = evdev_code,
                .pressed = true,
                .modifiers = self.modifiers(),
                .emit_event = false,
            });
        }

        self.callbacks.focus(self.callbacks.context, true);
    }

    fn leave(self: *Keyboard, surface: u32) void {
        if (!self.matchesSurface(surface)) return;
        self.clearFocus();
    }

    fn key(self: *Keyboard, _: u32, evdev_code: u32, state: u32) RuntimeError!void {
        if (!self.focused) return;
        switch (state) {
            0 => self.emitRelease(evdev_code),
            1 => {
                const mapped = try self.mappedKey(evdev_code);
                self.pressed.put(evdev_code, mapped);
                self.callbacks.key(self.callbacks.context, .{
                    .key = mapped,
                    .evdev_code = evdev_code,
                    .pressed = true,
                    .modifiers = self.modifiers(),
                });
                try self.emitText(evdev_code);

                const keymap_state = if (self.state) |*value| value else return error.MissingKeymap;
                const keycode = xkbKeycode(evdev_code) orelse return;
                self.repeat.begin(evdev_code, localMilliseconds(), keymap_state.keyRepeats(keycode));
            },
            else => return error.InvalidKeyboardEvent,
        }
    }

    fn updateModifiers(
        self: *Keyboard,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) RuntimeError!void {
        const state = if (self.state) |*value| value else return error.MissingKeymap;
        const mapping_state = if (self.mapping_state) |*value| value else return error.MissingKeymap;
        _ = state.update(.{
            .depressed_modifiers = depressed,
            .latched_modifiers = latched,
            .locked_modifiers = locked,
            .locked_layout = group,
        });
        _ = mapping_state.update(.{ .locked_layout = group });
    }

    fn repeatInfo(self: *Keyboard, rate: i32, delay: i32) error{InvalidRepeatInfo}!void {
        try self.repeat.configure(rate, delay);
    }

    fn emitPress(self: *Keyboard, evdev_code: u32, repeated: bool) RuntimeError!void {
        const mapped = self.pressed.get(evdev_code) orelse try self.mappedKey(evdev_code);
        self.callbacks.key(self.callbacks.context, .{
            .key = mapped,
            .evdev_code = evdev_code,
            .pressed = true,
            .modifiers = self.modifiers(),
            .repeated = repeated,
        });
        try self.emitText(evdev_code);
    }

    fn emitRelease(self: *Keyboard, evdev_code: u32) void {
        const mapped = self.pressed.remove(evdev_code) orelse self.mappedKey(evdev_code) catch .unknown;
        self.repeat.release(evdev_code);
        self.callbacks.key(self.callbacks.context, .{
            .key = mapped,
            .evdev_code = evdev_code,
            .pressed = false,
            .modifiers = self.modifiers(),
        });
    }

    fn emitText(self: *Keyboard, evdev_code: u32) RuntimeError!void {
        const modifiers_value = self.modifiers();
        if (modifiers_value.ctrl) return;

        const state = if (self.state) |*value| value else return error.MissingKeymap;
        const keycode = xkbKeycode(evdev_code) orelse return;
        _ = self.compose_state.feed(state.oneSymbol(keycode) orelse .no_symbol);

        var buffer: [text_buffer_capacity]u8 = undefined;
        const bytes = switch (self.compose_state.status()) {
            .composing => return,
            .composed => blk: {
                defer self.compose_state.reset();
                break :blk (self.compose_state.writeUtf8(&buffer) catch return) orelse return;
            },
            .cancelled => blk: {
                self.compose_state.reset();
                break :blk (state.writeUtf8(keycode, &buffer) catch return) orelse return;
            },
            .nothing => (state.writeUtf8(keycode, &buffer) catch return) orelse return,
        };

        const event = windowing.Event.textInput(bytes, modifiers_value) orelse return;
        self.callbacks.text(self.callbacks.context, event.text_input.text(), modifiers_value);
    }

    fn mappedKey(self: *Keyboard, evdev_code: u32) RuntimeError!windowing.Key {
        const state = if (self.mapping_state) |*value| value else return error.MissingKeymap;
        const keycode = xkbKeycode(evdev_code) orelse return .unknown;
        const symbol = state.oneSymbol(keycode) orelse return .unknown;
        return windowing.Key.fromKeysym(symbol);
    }

    fn releasePressed(self: *Keyboard, emit_event: bool) void {
        var evdev_code: usize = 0;
        while (evdev_code < self.pressed.entries.len) : (evdev_code += 1) {
            const mapped = self.pressed.entries[evdev_code] orelse continue;
            self.pressed.entries[evdev_code] = null;
            self.callbacks.key(self.callbacks.context, .{
                .key = mapped,
                .evdev_code = @intCast(evdev_code),
                .pressed = false,
                .modifiers = self.modifiers(),
                .emit_event = emit_event,
            });
        }
    }

    fn matchesSurface(self: *const Keyboard, surface: u32) bool {
        const expected = self.surface orelse return true;
        return surface == expected;
    }

    fn recordFailure(self: *Keyboard, err: RuntimeError) void {
        if (self.failure == null) self.failure = err;
    }
};

const PressedKeys = struct {
    entries: [sys.evdev.key_bit_count]?windowing.Key = @as([sys.evdev.key_bit_count]?windowing.Key, @splat(null)),

    fn put(self: *PressedKeys, evdev_code: u32, key: windowing.Key) void {
        const index = std.math.cast(usize, evdev_code) orelse return;
        if (index < self.entries.len) self.entries[index] = key;
    }

    fn get(self: *const PressedKeys, evdev_code: u32) ?windowing.Key {
        const index = std.math.cast(usize, evdev_code) orelse return null;
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }

    fn remove(self: *PressedKeys, evdev_code: u32) ?windowing.Key {
        const index = std.math.cast(usize, evdev_code) orelse return null;
        if (index >= self.entries.len) return null;
        const key = self.entries[index];
        self.entries[index] = null;
        return key;
    }

    fn modifiers(self: *const PressedKeys) windowing.Modifier {
        var result = windowing.Modifier{};
        for (self.entries) |entry| {
            switch (entry orelse continue) {
                .left_shift, .right_shift => result.shift = true,
                .left_ctrl, .right_ctrl => result.ctrl = true,
                .left_alt, .right_alt => result.alt = true,
                .left_super, .right_super => result.super = true,
                else => {},
            }
        }
        return result;
    }
};

const RepeatCandidate = struct {
    evdev_code: u32,
    pressed_ms: u32,
};

const RepeatState = struct {
    candidate: ?RepeatCandidate = null,
    rate_hz: u32 = 0,
    delay_ms: u32 = 0,
    next_tick: u64 = 0,

    fn configure(self: *RepeatState, rate: i32, delay: i32) error{InvalidRepeatInfo}!void {
        if (rate < 0 or delay < 0) return error.InvalidRepeatInfo;
        self.rate_hz = @intCast(rate);
        self.delay_ms = @intCast(delay);
        self.next_tick = 0;
    }

    fn begin(self: *RepeatState, evdev_code: u32, pressed_ms: u32, repeats: bool) void {
        if (!repeats) return;
        self.candidate = .{
            .evdev_code = evdev_code,
            .pressed_ms = pressed_ms,
        };
        self.next_tick = 0;
    }

    fn release(self: *RepeatState, evdev_code: u32) void {
        const candidate = self.candidate orelse return;
        if (candidate.evdev_code == evdev_code) self.cancel();
    }

    fn cancel(self: *RepeatState) void {
        self.candidate = null;
        self.next_tick = 0;
    }

    fn metadata(self: *const RepeatState) ?RepeatMetadata {
        const candidate = self.candidate orelse return null;
        if (self.rate_hz == 0) return null;
        return .{
            .evdev_code = candidate.evdev_code,
            .rate_hz = self.rate_hz,
            .delay_ms = self.delay_ms,
            .tick = self.next_tick,
            .deadline_ms = repeatDeadline(candidate.pressed_ms, self.delay_ms, self.rate_hz, self.next_tick),
        };
    }

    fn consume(self: *RepeatState, now_ms: u32) ?u32 {
        const next = self.metadata() orelse return null;
        if (!deadlineReached(now_ms, next.deadline_ms)) return null;

        const first_deadline = next.deadline_ms -% repeatOffset(self.rate_hz, next.tick);
        const elapsed = now_ms -% first_deadline;
        const elapsed_ticks = (@as(u128, elapsed) * self.rate_hz) / 1000;
        self.next_tick = std.math.cast(u64, elapsed_ticks + 1) orelse std.math.maxInt(u64);
        return next.evdev_code;
    }
};

fn xkbKeycode(evdev_code: u32) ?native_xkb.keymap.Keycode {
    return std.math.add(u32, evdev_code, 8) catch null;
}

fn processLocale() []const u8 {
    return chooseLocale(
        sys.env.getConstant("LC_ALL"),
        sys.env.getConstant("LC_CTYPE"),
        sys.env.getConstant("LANG"),
    );
}

fn localMilliseconds() u32 {
    const milliseconds = sys.time.milliTimestamp();
    return if (milliseconds <= 0) 0 else @truncate(@as(u64, @intCast(milliseconds)));
}

fn chooseLocale(lc_all: ?[]const u8, lc_ctype: ?[]const u8, lang: ?[]const u8) []const u8 {
    if (lc_all) |locale| if (locale.len != 0) return locale;
    if (lc_ctype) |locale| if (locale.len != 0) return locale;
    if (lang) |locale| if (locale.len != 0) return locale;
    return "C";
}

fn repeatDeadline(pressed_ms: u32, delay_ms: u32, rate_hz: u32, tick: u64) u32 {
    return pressed_ms +% delay_ms +% repeatOffset(rate_hz, tick);
}

fn repeatOffset(rate_hz: u32, tick: u64) u32 {
    const numerator = @as(u128, tick) * 1000;
    const offset = (numerator + rate_hz - 1) / rate_hz;
    return @truncate(offset);
}

fn deadlineReached(now_ms: u32, deadline_ms: u32) bool {
    return @as(i32, @bitCast(now_ms -% deadline_ms)) >= 0;
}

const keymap_format_xkb_v1: u32 = 1;
const text_buffer_capacity = 17;

fn test_sink_focus(_: *anyopaque, _: bool) void {}

fn test_sink_key(_: *anyopaque, _: KeyAction) void {}

fn test_sink_text(_: *anyopaque, _: []const u8, _: windowing.Modifier) void {}

const test_keymap_text =
    \\xkb_keymap {
    \\xkb_keycodes { <TEST> = 38; };
    \\xkb_types {
    \\    type "ALPHABETIC" {
    \\        modifiers=Shift+Lock;
    \\        map[Shift]=2;
    \\        map[Lock]=2;
    \\        level_name[1]="Base";
    \\        level_name[2]="Caps";
    \\    };
    \\};
    \\xkb_compatibility {};
    \\xkb_symbols {
    \\    key <TEST> {
    \\        symbols[1]=[ a, A ],
    \\        symbols[2]=[ x, X ],
    \\        repeat=Yes
    \\    };
    \\};
    \\};
;

test "pressed state preserves paired modifiers until both release" {
    var pressed = PressedKeys{};
    pressed.put(42, .left_shift);
    pressed.put(54, .right_shift);
    pressed.put(29, .left_ctrl);
    try std.testing.expect(pressed.modifiers().shift);
    try std.testing.expect(pressed.modifiers().ctrl);

    try std.testing.expectEqual(windowing.Key.left_shift, pressed.remove(42).?);
    try std.testing.expect(pressed.modifiers().shift);
    try std.testing.expectEqual(windowing.Key.right_shift, pressed.remove(54).?);
    try std.testing.expect(!pressed.modifiers().shift);
    try std.testing.expect(pressed.modifiers().ctrl);
}

test "keyboard modifiers include every XKB effective modifier" {
    var context: u8 = 0;
    var compose_storage = try native_xkb.compose.Storage.init(std.testing.allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    var compose_scratch = try native_xkb.compose.ScratchStorage.init(
        std.testing.allocator,
        native_xkb.compose.default_scratch_limits,
    );
    defer compose_scratch.deinit(std.testing.allocator);
    compose_storage.activate();
    compose_scratch.activate();
    const compose_table = try native_xkb.compose.compile(
        &compose_storage,
        &compose_scratch,
        "<A> : A\n",
        .{ .locale = "C" },
    );
    var keyboard = Keyboard{
        .allocator = std.testing.allocator,
        .callbacks = .{
            .context = &context,
            .focus = test_sink_focus,
            .key = test_sink_key,
            .text = test_sink_text,
        },
        .compose_storage = compose_storage,
        .compose_table = compose_table,
        .compose_state = native_xkb.compose.State.init(&compose_table),
    };
    defer keyboard.deinit();
    var storage: native_xkb.keymap.Keymap.Storage = undefined;
    keyboard.state = native_xkb.state.State.init(try native_xkb.keymap.Keymap.init(&storage, .{
        .modifiers = &native_xkb.keymap.core_modifiers,
        .types = &.{},
        .keys = &.{},
    }));

    const cases = [_]struct { mask: u32, expected: windowing.Modifier }{
        .{ .mask = 1 << 0, .expected = .{ .shift = true } },
        .{ .mask = 1 << 2, .expected = .{ .ctrl = true } },
        .{ .mask = 1 << 3, .expected = .{ .alt = true } },
        .{ .mask = 1 << 6, .expected = .{ .super = true } },
    };
    for (cases) |case| {
        if (keyboard.state) |*state| _ = state.update(.{ .depressed_modifiers = case.mask });
        try std.testing.expectEqual(case.expected, keyboard.modifiers());
    }
}

test "keyboard installs native TEXT V1 state transactionally" {
    const allocator = std.testing.allocator;
    var context: u8 = 0;
    var compose_storage = try native_xkb.compose.Storage.init(allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    var compose_scratch = try native_xkb.compose.ScratchStorage.init(
        allocator,
        native_xkb.compose.default_scratch_limits,
    );
    defer compose_scratch.deinit(allocator);
    compose_storage.activate();
    compose_scratch.activate();
    const compose_table = try native_xkb.compose.compile(
        &compose_storage,
        &compose_scratch,
        "<A> : A\n",
        .{ .locale = "C" },
    );
    var keyboard = Keyboard{
        .allocator = allocator,
        .callbacks = .{
            .context = &context,
            .focus = test_sink_focus,
            .key = test_sink_key,
            .text = test_sink_text,
        },
        .compose_storage = compose_storage,
        .compose_table = compose_table,
        .compose_state = native_xkb.compose.State.init(&compose_table),
    };
    defer keyboard.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "valid",
        .data = test_keymap_text ++ "\x00",
    });
    const valid = try temporary.dir.openFile(std.Options.debug_io, "valid", .{});
    try keyboard.attachKeymapFd(
        keymap_format_xkb_v1,
        valid.handle,
        @intCast(test_keymap_text.len + 1),
    );
    try keyboard.updateModifiers(1 << 0, 0, 0, 1);
    const state = if (keyboard.state) |*value| value else return error.MissingKeymap;
    const mapping_state = if (keyboard.mapping_state) |*value| value else return error.MissingKeymap;
    try std.testing.expectEqual(@as(?native_xkb.keysym.Keysym, @fromBackingInt(@intCast('X'))), state.oneSymbol(38));
    try std.testing.expectEqual(@as(?native_xkb.keysym.Keysym, @fromBackingInt(@intCast('x'))), mapping_state.oneSymbol(38));
    try std.testing.expect(state.keyRepeats(38));
    try std.testing.expectEqual(windowing.Key.x, try keyboard.mappedKey(30));
    try std.testing.expect(keyboard.modifiers().shift);

    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "invalid",
        .data = "not xkb\x00",
    });
    const invalid = try temporary.dir.openFile(std.Options.debug_io, "invalid", .{});
    try std.testing.expectError(
        error.InvalidSyntax,
        keyboard.attachKeymapFd(keymap_format_xkb_v1, invalid.handle, 8),
    );
    const retained = if (keyboard.state) |*value| value else return error.MissingKeymap;
    try std.testing.expectEqual(@as(?native_xkb.keysym.Keysym, @fromBackingInt(@intCast('X'))), retained.oneSymbol(38));
}

test "repeat state delays first tick and coalesces elapsed intervals" {
    var repeat = RepeatState{};
    try repeat.configure(25, 400);
    repeat.begin(30, 1000, true);

    try std.testing.expectEqual(@as(u32, 1400), repeat.metadata().?.deadline_ms);
    try std.testing.expect(repeat.consume(1399) == null);
    try std.testing.expectEqual(@as(u32, 30), repeat.consume(1400).?);
    try std.testing.expectEqual(@as(u32, 1440), repeat.metadata().?.deadline_ms);

    try std.testing.expectEqual(@as(u32, 30), repeat.consume(1525).?);
    try std.testing.expectEqual(@as(u64, 4), repeat.metadata().?.tick);
    try std.testing.expectEqual(@as(u32, 1560), repeat.metadata().?.deadline_ms);

    repeat.release(30);
    try std.testing.expect(repeat.metadata() == null);
}

test "repeat state handles disabled rates and millisecond wrap" {
    var repeat = RepeatState{};
    try repeat.configure(0, 300);
    repeat.begin(1, 10, true);
    try std.testing.expect(repeat.metadata() == null);

    try repeat.configure(20, 32);
    repeat.begin(1, std.math.maxInt(u32) - 15, true);
    try std.testing.expectEqual(@as(u32, 16), repeat.metadata().?.deadline_ms);
    try std.testing.expect(repeat.consume(15) == null);
    try std.testing.expectEqual(@as(u32, 1), repeat.consume(16).?);
    try std.testing.expectError(error.InvalidRepeatInfo, repeat.configure(-1, 0));
    try std.testing.expectError(error.InvalidRepeatInfo, repeat.configure(1, -1));
}

test "non-repeating modifiers do not displace the repeating key" {
    var repeat = RepeatState{};
    try repeat.configure(30, 500);
    repeat.begin(30, 100, true);
    repeat.begin(42, 200, false);
    try std.testing.expectEqual(@as(u32, 30), repeat.metadata().?.evdev_code);
    try std.testing.expectEqual(@as(u32, 600), repeat.metadata().?.deadline_ms);
}

test "locale selection follows POSIX precedence and ignores empty values" {
    try std.testing.expectEqualStrings("all", chooseLocale("all", "ctype", "lang"));
    try std.testing.expectEqualStrings("ctype", chooseLocale("", "ctype", "lang"));
    try std.testing.expectEqualStrings("lang", chooseLocale(null, null, "lang"));
    try std.testing.expectEqualStrings("C", chooseLocale(null, "", null));
}

test "Wayland keyboard roots bounded native Compose storage" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("xkb").compose.Storage, "xkb_compose_consumer"),
        );
    }

    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    const compose_path = try std.fs.path.join(allocator, &.{ root, "XCompose" });
    defer allocator.free(compose_path);
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "XCompose",
        .data = "<Multi_key> <a> : \"å\" aring\n",
    });

    var context: u8 = 0;
    var keyboard = try Keyboard.init(allocator, .{
        .context = &context,
        .focus = test_sink_focus,
        .key = test_sink_key,
        .text = test_sink_text,
    }, .{
        .locale = "C",
        .compose_file = compose_path,
        .compose_limits = .{ .sequence_symbols = 2, .text_bytes = 2 },
        .compose_scratch_limits = native_xkb.compose.default_scratch_limits,
    });
    defer keyboard.deinit();

    try std.testing.expect(keyboard.repeatMetadata() == null);
    const status = keyboard.compose_storage.status();
    try std.testing.expect(status.in_use);
    try std.testing.expectEqual(@as(usize, 2), status.sequence_symbols);
    try std.testing.expectEqual(@as(usize, 2), status.text_bytes);
    try std.testing.expectEqual(@as(usize, 3), status.used_nodes);
    try std.testing.expectEqual(@as(usize, 2), status.used_edges);
    try std.testing.expectEqual(@as(usize, 2), status.used_text_bytes);
}

test "Wayland keyboard roots bounded native Compose loading scratch" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("xkb").compose.ScratchStorage,
                "xkb_compose_scratch_consumer",
            ),
        );
    }

    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    const compose_path = try std.fs.path.join(allocator, &.{ root, "XCompose" });
    defer allocator.free(compose_path);
    const source = "<A> : A\n";
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "XCompose",
        .data = source,
    });

    var context: u8 = 0;
    var keyboard = try Keyboard.init(allocator, .{
        .context = &context,
        .focus = test_sink_focus,
        .key = test_sink_key,
        .text = test_sink_text,
    }, .{
        .locale = "C",
        .compose_file = compose_path,
        .compose_limits = .{ .sequence_symbols = 1, .text_bytes = 0 },
        .compose_scratch_limits = .{
            .line_bytes = source.len - 1,
            .path_bytes = 1,
        },
    });
    defer keyboard.deinit();
    try std.testing.expectEqual(@as(usize, 2), keyboard.compose_storage.status().used_nodes);
}
