const std = @import("std");
const native_xkb = @import("xkb");
const sys = @import("sys");
const clipboard = @import("clipboard.zig");
const event_module = @import("event.zig");
const Event = event_module.Event;
const EventIterator = event_module.EventIterator;
const CursorShape = @import("cursor.zig").CursorShape;
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");
const surface = @import("surface.zig");
const Key = @import("key.zig").Key;
const MouseButton = @import("mouse.zig").MouseButton;
const Modifier = @import("modifier.zig").Modifier;
const WindowConfig = @import("config.zig").WindowConfig;
const CreateError = @import("window.zig").CreateError;
const PollError = @import("window.zig").PollError;
const PresentError = @import("window.zig").PresentError;
const PresentRegion = @import("window.zig").PresentRegion;
const Scale = @import("window.zig").Scale;
const Size = @import("window.zig").Size;
const presentation = @import("presentation.zig");
const frame_model = @import("frame.zig");
const PresentationOutcome = presentation.Outcome;
const PresentationStatus = presentation.Status;
const PresentationStorageStatus = presentation.StorageStatus;
const WaylandStorageStatus = @import("wayland").runtime.StorageStatus;

const x11 = sys.x11;
const protocol = x11.protocol;

const max_keycode_slots = 256;
const keysym_columns = 2;
const clipboard_wait_ms = 1000;
const max_core_request_bytes = 65535 * 4;

const iconic_state: u32 = 3;
const net_wm_state_remove: u32 = 0;
const net_wm_state_add: u32 = 1;
const substructure_mask: u32 = 0x0018_0000;

const cursor_font_name = "cursor";

fn deriveConnectionCapacity(
    event_capacity: event_module.Capacity,
    clipboard_capacity: clipboard.Capacity,
    request_byte_count: usize,
    reply_byte_count: usize,
) x11.CapacityError!x11.Capacity {
    const publication_padded_byte_count = std.math.add(
        usize,
        clipboard_capacity.published_text_byte_count,
        protocol.pad4(clipboard_capacity.published_text_byte_count),
    ) catch return error.CapacityOverflow;
    const publication_request_byte_count = std.math.add(
        usize,
        24,
        publication_padded_byte_count,
    ) catch return error.CapacityOverflow;
    if (request_byte_count < publication_request_byte_count) {
        return error.RequestStorageTooSmall;
    }
    const retained_message_count = std.math.add(
        usize,
        event_capacity.retained_event_count,
        clipboard_capacity.retained_wait_event_count,
    ) catch return error.CapacityOverflow;
    const clipboard_reply_byte_count = std.math.mul(
        usize,
        clipboard_capacity.x11_property_long_count,
        4,
    ) catch return error.CapacityOverflow;
    const minimum_reply_byte_count = @max(
        clipboard_reply_byte_count,
        protocol.maximum_keyboard_mapping_reply_byte_count,
    );
    if (reply_byte_count < minimum_reply_byte_count) {
        return error.ReplyStorageTooSmall;
    }
    return x11.Capacity.derive(.{
        .retained_message_count = retained_message_count,
        .request_byte_count = request_byte_count,
        .reply_byte_count = reply_byte_count,
    });
}

const Atoms = struct {
    wm_protocols: u32,
    wm_delete_window: u32,
    net_wm_name: u32,
    utf8_string: u32,
    wm_normal_hints: u32,
    wm_size_hints: u32,
    wm_change_state: u32,
    net_wm_state: u32,
    net_wm_state_max_horz: u32,
    net_wm_state_max_vert: u32,
    clipboard: u32,
    windowing_selection: u32,
    targets: u32,
    atom: u32,
};

const Pixmap = struct {
    id: u32,
    width: u32,
    height: u32,
    valid: bool = false,
};

const Acquisition = struct {
    pixmap: Pixmap,
    observation: x11.connection.ReplyObservation,
};

pub const X11Backend = struct {
    pixmap: ?Pixmap = null,
    acquisition: ?Acquisition = null,
    refused_extent: ?Size = null,
    ids: frame_model.Ids = .{},
    pixmap_refusal_count: u64 = 0,
    direct_frame_count: u64 = 0,
    empty_region_fallback_count: u64 = 0,
    connection: x11.Connection,
    window: u32,
    gc: u32,
    atoms: Atoms,
    width: u32,
    height: u32,
    should_close: bool = false,
    input: input.State,
    gamepads: gamepad.State,
    clipboard_capacity: clipboard.Capacity,
    clipboard_source: clipboard.Source,
    clipboard_wait_events: clipboard.WaitEvents,
    events: event_module.Queue,
    keysyms: [max_keycode_slots][keysym_columns]u32 = @splat(@splat(0)),
    cursor_font: u32 = 0,
    cursors: [cursor_shape_count]u32 = @splat(0),
    cursor_on_screen: bool = false,
    red_shift: u5 = 16,
    green_shift: u5 = 8,
    blue_shift: u5 = 0,
    packed_region: PackedRegionStorage,

    const cursor_shape_count = @typeInfo(CursorShape).@"enum".field_names.len;

    pub fn init(self: *X11Backend, allocator: std.mem.Allocator, config: WindowConfig) CreateError!void {
        const clipboard_capacity = clipboard.Capacity.derive(config.clipboard) catch
            return error.InvalidCapacity;
        const event_capacity = event_module.Capacity.derive(config.events) catch
            return error.InvalidCapacity;
        const connection_capacity = deriveConnectionCapacity(
            event_capacity,
            clipboard_capacity,
            config.x11_request_byte_count,
            config.x11_reply_byte_count,
        ) catch return error.InvalidCapacity;
        const input_capacity = input.Capacity.derive(config.input) catch
            return error.InvalidCapacity;
        const gamepad_capacity = gamepad.Capacity.derive(config.gamepads) catch
            return error.InvalidCapacity;
        const presentation_capacity = presentation.Capacity.derive(
            config.presentation,
        ) catch return error.InvalidCapacity;
        var packed_region = PackedRegionStorage.init(
            allocator,
            presentation_capacity.x11_packed_region_bytes,
        ) catch return error.OutOfMemory;
        errdefer packed_region.deinit();
        self.* = .{
            .connection = x11.Connection.connect(allocator, connection_capacity) catch |err| switch (err) {
                error.OutOfMemory, error.ConnectionFailed, error.AuthenticationFailed => return error.ConnectionFailed,
                else => return error.UnsupportedPlatform,
            },
            .window = 0,
            .gc = 0,
            .atoms = undefined,
            .width = config.width,
            .height = config.height,
            .input = undefined,
            .gamepads = undefined,
            .clipboard_capacity = clipboard_capacity,
            .clipboard_source = undefined,
            .clipboard_wait_events = undefined,
            .events = undefined,
            .packed_region = packed_region,
        };
        errdefer self.connection.close();
        self.events = event_module.Queue.init(allocator, event_capacity) catch
            return error.OutOfMemory;
        errdefer self.events.deinit();
        self.input = input.State.init(allocator, input_capacity) catch
            return error.OutOfMemory;
        errdefer self.input.deinit();
        self.gamepads = gamepad.State.init(allocator, gamepad_capacity) catch
            return error.OutOfMemory;
        errdefer self.gamepads.deinit();
        self.clipboard_wait_events = clipboard.WaitEvents.init(
            allocator,
            clipboard_capacity,
        ) catch return error.OutOfMemory;
        errdefer self.clipboard_wait_events.deinit();
        self.clipboard_source = clipboard.Source.init(
            allocator,
            clipboard_capacity,
        ) catch return error.OutOfMemory;
        errdefer self.clipboard_source.deinit();

        self.atoms = internAtoms(&self.connection) catch return error.ConnectionFailed;
        self.red_shift = maskShift(self.connection.setup.red_mask, 16);
        self.green_shift = maskShift(self.connection.setup.green_mask, 8);
        self.blue_shift = maskShift(self.connection.setup.blue_mask, 0);

        self.window = self.connection.generateId();
        self.gc = self.connection.generateId();

        self.createWindow(config) catch return error.WindowCreationFailed;
        self.loadKeyboardMapping() catch return error.WindowCreationFailed;
    }

    pub fn deinit(self: *X11Backend) void {
        self.gamepads.deinit();
        self.input.deinit();
        self.events.deinit();
        self.clipboard_source.deinit();
        self.clipboard_wait_events.deinit();
        self.packed_region.deinit();
        const request = self.connection.beginRequest();
        if (self.pixmap) |pixmap| protocol.freeResource(request, .free_pixmap, pixmap.id) catch {};
        if (self.acquisition) |pending| {
            if (pending.observation.failure == null) protocol.freeResource(request, .free_pixmap, pending.pixmap.id) catch {};
        }
        protocol.freeResource(request, .free_gc, self.gc) catch {};
        protocol.windowRequest(request, .destroy_window, self.window) catch {};
        self.connection.sendRequest() catch {};
        self.connection.close();
    }

    fn createWindow(self: *X11Backend, config: WindowConfig) !void {
        const setup = self.connection.setup;
        const events = protocol.event_mask.key_press |
            protocol.event_mask.key_release |
            protocol.event_mask.button_press |
            protocol.event_mask.button_release |
            protocol.event_mask.enter_window |
            protocol.event_mask.leave_window |
            protocol.event_mask.pointer_motion |
            protocol.event_mask.exposure |
            protocol.event_mask.structure_notify |
            protocol.event_mask.focus_change;

        const request = self.connection.beginRequest();
        try protocol.createWindow(request, .{
            .window = self.window,
            .parent = setup.root,
            .depth = setup.root_depth,
            .visual = setup.root_visual,
            .width = clampU16(config.width),
            .height = clampU16(config.height),
            .events = events,
        });
        try protocol.createGc(request, self.gc, self.window);
        try self.connection.sendRequest();

        var delete_atom: [4]u8 = undefined;
        std.mem.writeInt(u32, &delete_atom, self.atoms.wm_delete_window, .little);
        try self.changePropertyBytes(self.atoms.wm_protocols, self.atoms.atom, 32, &delete_atom);
        self.applyTitle(config.title);
        if (!config.resizable) {
            self.applySizeBounds(config.width, config.height, config.width, config.height);
        }

        if (config.visible) {
            const map = self.connection.beginRequest();
            try protocol.windowRequest(map, .map_window, self.window);
            try self.connection.sendRequest();
        }
    }

    fn loadKeyboardMapping(self: *X11Backend) !void {
        const setup = self.connection.setup;
        const count = setup.max_keycode - setup.min_keycode + 1;
        const request = self.connection.beginRequest();
        try protocol.getKeyboardMapping(request, setup.min_keycode, count);
        try self.connection.sendRequest();
        const reply = try self.connection.waitReply();

        const per_keycode = reply.dataByte();
        if (per_keycode == 0) return;
        var keycode: usize = setup.min_keycode;
        var offset: usize = 0;
        while (keycode <= setup.max_keycode and offset + 4 <= reply.extra.len) : (keycode += 1) {
            var column: usize = 0;
            while (column < keysym_columns) : (column += 1) {
                const source = offset + column * 4;
                if (column < per_keycode and source + 4 <= reply.extra.len) {
                    self.keysyms[keycode][column] = std.mem.readInt(u32, reply.extra[source..][0..4], .little);
                }
            }
            offset += @as(usize, per_keycode) * 4;
        }
    }

    pub fn pollEvents(self: *X11Backend) PollError!EventIterator {
        self.input.beginPoll();
        self.gamepads.poll();
        self.events.beginPoll();

        while (true) {
            const message = self.connection.nextMessage() catch return error.ConnectionLost;
            const raw = message orelse break;
            if (try self.observeAcquisition(raw)) continue;
            self.translate(protocol.decodeMessage(&raw));
        }

        return self.events.iterator();
    }

    pub fn shouldClose(self: *const X11Backend) bool {
        return self.should_close;
    }

    pub fn eventSource(self: *const X11Backend) ?@import("window.zig").EventSource {
        return .{ .descriptor = self.connection.stream.handle };
    }

    pub fn getSize(self: *const X11Backend) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn inputState(self: *const X11Backend) *const input.State {
        return &self.input;
    }

    pub fn inputStateMut(self: *X11Backend) *input.State {
        return &self.input;
    }

    pub fn gamepadState(self: *const X11Backend) *const gamepad.State {
        return &self.gamepads;
    }

    fn translate(self: *X11Backend, message: protocol.Message) void {
        switch (message) {
            .key_press => |key| {
                const modifiers = modifiersFromState(key.state);
                const keysym = self.keysymFor(key.keycode, key.state);
                const mapped = Key.fromKeysym(
                    @fromBackingInt(self.keysyms[key.keycode][0]),
                );
                self.input.pressKey(mapped);
                self.push(.{ .key_press = .{ .key = mapped, .modifiers = modifiers } });
                if (!modifiers.ctrl) {
                    var buffer: [4]u8 = undefined;
                    if (textFromKeysym(keysym, &buffer)) |bytes| {
                        if (Event.textInput(bytes, modifiers)) |text_event| {
                            if (self.input.pushTextInput(bytes)) {
                                self.push(text_event);
                            }
                        }
                    }
                }
            },
            .key_release => |key| {
                const mapped = Key.fromKeysym(
                    @fromBackingInt(self.keysyms[key.keycode][0]),
                );
                self.input.releaseKey(mapped);
                self.push(.{ .key_release = .{ .key = mapped, .modifiers = modifiersFromState(key.state) } });
            },
            .button_press => |button| {
                const modifiers = modifiersFromState(button.state);
                if (wheelFromButton(button.button)) |wheel| {
                    self.input.mouse_wheel.x += wheel[0];
                    self.input.mouse_wheel.y += wheel[1];
                    self.push(.{ .mouse_wheel = .{
                        .x = button.x,
                        .y = button.y,
                        .delta_x = wheel[0],
                        .delta_y = wheel[1],
                        .modifiers = modifiers,
                    } });
                } else if (mouseButtonFromCode(button.button)) |mapped| {
                    self.input.pressMouse(mapped);
                    self.push(.{ .mouse_press = .{
                        .button = mapped,
                        .x = button.x,
                        .y = button.y,
                        .modifiers = modifiers,
                    } });
                }
            },
            .button_release => |button| {
                if (wheelFromButton(button.button) != null) return;
                if (mouseButtonFromCode(button.button)) |mapped| {
                    self.input.releaseMouse(mapped);
                    self.push(.{ .mouse_release = .{
                        .button = mapped,
                        .x = button.x,
                        .y = button.y,
                        .modifiers = modifiersFromState(button.state),
                    } });
                }
            },
            .motion => |motion| {
                const previous = self.input.mouse_position;
                self.input.mouse_position = .{ .x = motion.x, .y = motion.y };
                self.input.mouse_delta.x += motion.x - previous.x;
                self.input.mouse_delta.y += motion.y - previous.y;
                self.push(.{ .mouse_move = .{ .x = motion.x, .y = motion.y } });
            },
            .configure => |configure| {
                if (configure.window != self.window) return;
                const width: u32 = configure.width;
                const height: u32 = configure.height;
                if (width == self.width and height == self.height) return;
                self.width = width;
                self.height = height;
                self.push(.{ .window_resize = .{ .width = width, .height = height } });
            },
            .client_message => |client| {
                if (client.message_type == self.atoms.wm_protocols and client.data[0] == self.atoms.wm_delete_window) {
                    self.should_close = true;
                    self.push(.window_close);
                }
            },
            .focus => |focus| {
                if (focus.mode != 0) return;
                self.push(.{ .window_focus = .{ .focused = focus.focused } });
            },
            .destroy_notify => {
                self.should_close = true;
                self.push(.window_close);
            },
            .selection_clear => |selection| {
                if (selection.owner == self.window and selection.selection == self.atoms.clipboard) {
                    self.clipboard_source.clear();
                }
            },
            .selection_request => |selection| self.serveClipboardRequest(selection),
            .enter => self.cursor_on_screen = true,
            .leave => self.cursor_on_screen = false,
            .expose, .selection_notify, .protocol_error, .reply, .ignored => {},
        }
    }

    fn push(self: *X11Backend, event: Event) void {
        _ = self.events.push(event);
    }

    fn keysymFor(
        self: *const X11Backend,
        keycode: u8,
        state: u16,
    ) native_xkb.keysym.Keysym {
        const shifted = (state & protocol.state_mask.shift) != 0;
        const locked = (state & protocol.state_mask.lock) != 0;
        var keysym = self.keysyms[keycode][0];
        if (shifted and self.keysyms[keycode][1] != 0) {
            keysym = self.keysyms[keycode][1];
        }
        if (locked and !shifted and keysym >= 'a' and keysym <= 'z') {
            keysym = keysym - 'a' + 'A';
        }
        return @fromBackingInt(keysym);
    }

    pub fn getFramebufferSize(self: *const X11Backend) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn nativeSurface(self: *X11Backend) surface.Surface {
        const extent = surface.extentFromSizes(
            self.width,
            self.height,
            self.width,
            self.height,
            1,
            1,
        );
        return .{ .x11 = .{
            .connection = &self.connection,
            .display = self.connection.target,
            .window = self.window,
            .screen = self.connection.screen,
            .root = self.connection.setup.root,
            .visual = self.connection.setup.visual,
            .depth = self.connection.setup.visual_depth,
            .red_mask = self.connection.setup.red_mask,
            .green_mask = self.connection.setup.green_mask,
            .blue_mask = self.connection.setup.blue_mask,
            .extent = extent,
        } };
    }

    pub fn getContentScale(_: *const X11Backend) Scale {
        return .{ .x = 1, .y = 1 };
    }

    pub fn presentRgba8(
        self: *X11Backend,
        rgba8: []const u8,
        width: u32,
        height: u32,
    ) PresentError!void {
        return self.presentRgba8Region(rgba8, width, height, PresentRegion.full(width, height));
    }

    pub fn presentRgba8Region(
        self: *X11Backend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        region: PresentRegion,
    ) PresentError!void {
        if (width == 0 or height == 0) return;
        const frame_byte_count = presentation.rgba8ByteCount(width, height) orelse
            return error.UnsupportedFormat;
        if (rgba8.len < frame_byte_count) return error.UnsupportedFormat;
        const active_region = region.clamped(width, height);
        if (active_region.pixelCount() == 0) return;

        _ = try self.presentRgba8Frame(rgba8, width, height, &.{active_region});
    }

    pub fn presentRgba8Frame(
        self: *X11Backend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        regions: []const PresentRegion,
    ) PresentError!u64 {
        var frame = try frame_model.Frame.init(rgba8, width, height, regions);
        if (width > std.math.maxInt(i16) or height > std.math.maxInt(i16)) return error.UnsupportedFormat;
        _ = self.packed_region.prepare(frame.byte_count) catch return error.CapacityExceeded;
        const id = try self.ids.reserve();
        try self.ensurePixmap(width, height);
        const drawable = if (self.pixmap) |pixmap|
            if (self.acquisition == null and pixmap.width == width and pixmap.height == height) pixmap.id else self.window
        else
            self.window;
        if (drawable != self.window) {
            if (!self.pixmap.?.valid) frame.cover();
            self.pixmap.?.valid = false;
        } else {
            frame.cover();
            if (self.pixmap) |*pixmap| pixmap.valid = false;
        }
        for (frame.slice()) |region| try self.uploadRegion(drawable, rgba8, width, region);
        if (drawable != self.window) {
            const box = frame.bounds();
            const request = self.connection.beginRequest();
            protocol.copyArea(request, .{
                .source = drawable,
                .destination = self.window,
                .gc = self.gc,
                .source_x = @intCast(box.x),
                .source_y = @intCast(box.y),
                .destination_x = @intCast(box.x),
                .destination_y = @intCast(box.y),
                .width = @intCast(box.width),
                .height = @intCast(box.height),
            }) catch return error.CapacityExceeded;
            self.connection.sendRequest() catch return error.Unexpected;
            self.pixmap.?.valid = true;
        } else {
            self.direct_frame_count +|= 1;
        }
        self.ids.accept(id);
        if (frame.empty_fallback) self.empty_region_fallback_count +|= 1;
        return id;
    }

    /// Ensures the window has an offscreen server pixmap sized to `width * height * 4` bytes, held entirely
    /// in X server storage outside caller allocator accounting. On resize, the backend acquires the
    /// replacement pixmap before releasing the previous resource. Wire
    /// coordinates for upload and copy requests are limited to 32767 (`i16`), and hardware presentation
    /// extensions such as Present and MIT-SHM are out of scope.
    ///
    /// To confirm allocation, the backend follows `CreatePixmap` (major opcode 53) with a
    /// `GetInputFocus` barrier request (opcode 43), matching `BadAlloc` errors by error code 11, major opcode 53,
    /// and the low 16 bits of the sequence number while ignoring unused bytes 4 through 7. While waiting for the
    /// barrier reply, incoming messages are retained up to `retained_message_count` (default 320 messages: 256
    /// input events and 64 clipboard events, totaling 10240 raw bytes). Retention overflow yields a typed sys
    /// error, increments the retention counter, and preserves the existing message queue, the blocked head
    /// message, and the active observer. Frames submitted during pending acquisition or following `BadAlloc`
    /// upload directly to the window and increment `x11_direct_frame_count` while acquisition remains pending, or for the refused extent. Pending acquisition blocks synchronous clipboard and maximized window queries, returning null
    /// or false, while other protocol failures remain typed.
    fn ensurePixmap(self: *X11Backend, width: u32, height: u32) PresentError!void {
        if (self.acquisition != null) return;
        if (self.refused_extent) |extent| {
            if (extent.width == width and extent.height == height) return;
            self.refused_extent = null;
        }
        if (self.pixmap) |pixmap| {
            if (pixmap.width == width and pixmap.height == height) return;
        }
        const pixmap = Pixmap{ .id = self.connection.generateId(), .width = width, .height = height };
        const sequence = self.connection.nextRequestSequence();
        const request = self.connection.beginRequest();
        protocol.createPixmap(request, .{
            .depth = self.connection.setup.root_depth,
            .pixmap = pixmap.id,
            .drawable = self.window,
            .width = @intCast(width),
            .height = @intCast(height),
        }) catch return error.CapacityExceeded;
        protocol.getInputFocus(request) catch return error.CapacityExceeded;
        self.connection.sendRequest() catch return error.Unexpected;
        self.acquisition = .{ .pixmap = pixmap, .observation = .{
            .request_sequence = sequence,
            .reply_sequence = sequence +% 1,
            .request_opcode = @backingInt(protocol.Opcode.create_pixmap),
        } };
        _ = self.connection.waitReplyObserved(&self.acquisition.?.observation) catch |err| switch (err) {
            error.RetainedMessageCapacityExceeded => return,
            else => return error.Unexpected,
        };
        try self.completeAcquisition();
    }

    fn observeAcquisition(self: *X11Backend, raw: x11.connection.Message) PollError!bool {
        const pending = if (self.acquisition) |*value| value else return false;
        if (raw[0] == 0) {
            const failure = protocol.ErrorPacket.decode(&raw);
            if (failure.sequence == pending.observation.request_sequence and failure.major_opcode == pending.observation.request_opcode) {
                pending.observation.failure = failure;
                return true;
            }
        }
        if (raw[0] == 1 and std.mem.readInt(u16, raw[2..4], .little) == pending.observation.reply_sequence) {
            self.completeAcquisition() catch return error.PresentationFailed;
            return true;
        }
        return false;
    }

    fn completeAcquisition(self: *X11Backend) PresentError!void {
        const pending = self.acquisition.?;
        self.acquisition = null;
        if (pending.observation.failure) |failure| {
            if (failure.code != 11) return error.Unexpected;
            self.refused_extent = .{ .width = pending.pixmap.width, .height = pending.pixmap.height };
            self.pixmap_refusal_count +|= 1;
            return;
        }
        const old = self.pixmap;
        self.pixmap = pending.pixmap;
        if (old) |pixmap| {
            const request = self.connection.beginRequest();
            protocol.freeResource(request, .free_pixmap, pixmap.id) catch return error.CapacityExceeded;
            self.connection.sendRequest() catch return error.Unexpected;
        }
    }

    fn uploadRegion(self: *X11Backend, drawable: u32, rgba8: []const u8, width: u32, active_region: PresentRegion) PresentError!void {
        const packed_byte_count = try regionByteCount(active_region);
        const packed_pixels = self.packed_region.prepare(packed_byte_count) catch return error.CapacityExceeded;
        self.packPixelsRegion(rgba8, width, packed_pixels, active_region);
        const row_bytes = @as(usize, active_region.width) * 4;
        const budget = @min(self.connection.maxRequestBytes(), max_core_request_bytes) - 32;
        if (row_bytes > budget) return error.CapacityExceeded;
        const rows_per_request = budget / row_bytes;
        var row: usize = 0;
        while (row < active_region.height) {
            const rows = @min(rows_per_request, active_region.height - row);
            const request = self.connection.beginRequest();
            protocol.putImageRows(request, .{
                .drawable = drawable,
                .gc = self.gc,
                .width = @intCast(active_region.width),
                .row_count = @intCast(rows),
                .dst_x = @intCast(active_region.x),
                .dst_y = @intCast(active_region.y + @as(u32, @intCast(row))),
                .depth = self.connection.setup.root_depth,
                .pixels = packed_pixels[row * row_bytes .. (row + rows) * row_bytes],
            }) catch return error.CapacityExceeded;
            self.connection.sendRequest() catch return error.Unexpected;
            row += rows;
        }
    }

    fn packPixelsRegion(self: *const X11Backend, rgba8: []const u8, frame_width: u32, out: []u8, region: PresentRegion) void {
        packRegionRgba8(rgba8, frame_width, out, region, self.pixelPacking());
    }

    fn pixelPacking(self: *const X11Backend) PixelPacking {
        return .{
            .endian = if (self.connection.setup.image_byte_order_msb) .big else .little,
            .red_shift = self.red_shift,
            .green_shift = self.green_shift,
            .blue_shift = self.blue_shift,
        };
    }

    pub fn setTitle(self: *X11Backend, title: [:0]const u8) void {
        self.applyTitle(title);
    }

    fn applyTitle(self: *X11Backend, title: [:0]const u8) void {
        self.changePropertyBytes(self.atoms.net_wm_name, self.atoms.utf8_string, 8, title) catch {};
    }

    pub fn setMinSize(self: *X11Backend, width: u32, height: u32) void {
        self.applySizeBounds(width, height, 0, 0);
    }

    fn applySizeBounds(self: *X11Backend, min_width: u32, min_height: u32, max_width: u32, max_height: u32) void {
        var hints = @as([18]u32, @splat(0));
        hints[0] = 16;
        hints[5] = min_width;
        hints[6] = min_height;
        if (max_width != 0 and max_height != 0) {
            hints[0] |= 32;
            hints[7] = max_width;
            hints[8] = max_height;
        }
        var bytes: [18 * 4]u8 = undefined;
        for (hints, 0..) |word, i| {
            std.mem.writeInt(u32, bytes[i * 4 ..][0..4], word, .little);
        }
        self.changePropertyBytes(self.atoms.wm_normal_hints, self.atoms.wm_size_hints, 32, &bytes) catch {};
    }

    pub fn setCursor(self: *X11Backend, shape: CursorShape) void {
        const cursor = self.cursorFor(shape) orelse return;
        const request = self.connection.beginRequest();
        protocol.changeCursor(request, self.window, cursor) catch return;
        self.connection.sendRequest() catch {};
    }

    fn cursorFor(self: *X11Backend, shape: CursorShape) ?u32 {
        const index = @backingInt(shape);
        if (self.cursors[index] != 0) return self.cursors[index];

        if (self.cursor_font == 0) {
            self.cursor_font = self.connection.generateId();
            const request = self.connection.beginRequest();
            protocol.openFont(request, self.cursor_font, cursor_font_name) catch return null;
            self.connection.sendRequest() catch return null;
        }

        const cursor = self.connection.generateId();
        const request = self.connection.beginRequest();
        protocol.createGlyphCursor(request, .{
            .cursor = cursor,
            .font = self.cursor_font,
            .glyph = cursorGlyph(shape),
        }) catch return null;
        self.connection.sendRequest() catch return null;
        self.cursors[index] = cursor;
        return cursor;
    }

    pub fn isCursorOnScreen(self: *const X11Backend) bool {
        return self.cursor_on_screen;
    }

    pub fn minimize(self: *X11Backend) void {
        self.sendStateMessage(self.atoms.wm_change_state, .{ iconic_state, 0, 0, 0, 0 });
    }

    pub fn maximize(self: *X11Backend) void {
        self.sendStateMessage(self.atoms.net_wm_state, .{
            net_wm_state_add,
            self.atoms.net_wm_state_max_horz,
            self.atoms.net_wm_state_max_vert,
            1,
            0,
        });
    }

    pub fn restore(self: *X11Backend) void {
        self.sendStateMessage(self.atoms.net_wm_state, .{
            net_wm_state_remove,
            self.atoms.net_wm_state_max_horz,
            self.atoms.net_wm_state_max_vert,
            1,
            0,
        });
        const request = self.connection.beginRequest();
        protocol.windowRequest(request, .map_window, self.window) catch return;
        self.connection.sendRequest() catch {};
    }

    fn sendStateMessage(self: *X11Backend, message_type: u32, data: [5]u32) void {
        const request = self.connection.beginRequest();
        protocol.sendClientMessage(request, self.connection.setup.root, substructure_mask, .{
            .window = self.window,
            .message_type = message_type,
            .data = data,
        }) catch return;
        self.connection.sendRequest() catch {};
    }

    pub fn isMaximized(self: *X11Backend) bool {
        if (self.acquisition != null) return false;
        const request = self.connection.beginRequest();
        protocol.getProperty(request, .{
            .window = self.window,
            .property = self.atoms.net_wm_state,
            .property_type = self.atoms.atom,
            .long_length = 64,
        }) catch return false;
        self.connection.sendRequest() catch return false;
        const reply = self.connection.waitReply() catch return false;

        var horizontal = false;
        var vertical = false;
        var offset: usize = 0;
        while (offset + 4 <= reply.extra.len) : (offset += 4) {
            const atom = std.mem.readInt(u32, reply.extra[offset..][0..4], .little);
            if (atom == self.atoms.net_wm_state_max_horz) horizontal = true;
            if (atom == self.atoms.net_wm_state_max_vert) vertical = true;
        }
        return horizontal and vertical;
    }

    pub fn getClipboardTextAlloc(self: *X11Backend, allocator: std.mem.Allocator) !?[]u8 {
        if (self.acquisition != null) return null;
        const request = self.connection.beginRequest();
        protocol.convertSelection(request, .{
            .requestor = self.window,
            .selection = self.atoms.clipboard,
            .target = self.atoms.utf8_string,
            .property = self.atoms.windowing_selection,
        }) catch return null;
        self.connection.sendRequest() catch return null;

        self.clipboard_wait_events.reset();
        var restore_wait_events = true;
        defer if (restore_wait_events) self.restoreClipboardWaitEvents();
        var property: u32 = protocol.atom_none;
        var waited: u32 = 0;
        wait: while (waited < clipboard_wait_ms) {
            if (!self.clipboard_wait_events.admitNext()) {
                return error.ClipboardWaitCapacityExceeded;
            }
            while (self.connection.nextMessage() catch return null) |raw| {
                const message = protocol.decodeMessage(&raw);
                switch (message) {
                    .selection_notify => |selection| {
                        property = selection.property;
                        break :wait;
                    },
                    .selection_request => |selection| self.serveClipboardRequest(selection),
                    .selection_clear => |selection| {
                        if (selection.owner == self.window and selection.selection == self.atoms.clipboard) {
                            self.clipboard_source.clear();
                        }
                    },
                    else => {
                        self.clipboard_wait_events.appendAssumeCapacity(raw);
                        if (self.clipboard_wait_events.full()) continue :wait;
                    },
                }
            }
            const readable = self.connection.waitReadable(50) catch return null;
            if (!readable) waited += 50;
        }
        if (property == protocol.atom_none) return null;
        self.restoreClipboardWaitEvents();
        restore_wait_events = false;

        const fetch = self.connection.beginRequest();
        protocol.getProperty(fetch, .{
            .window = self.window,
            .property = property,
            .property_type = self.atoms.utf8_string,
            .long_length = self.clipboard_capacity.x11_property_long_count,
            .delete = true,
        }) catch return null;
        self.connection.sendRequest() catch return null;
        const reply = self.connection.waitReply() catch return null;

        const value_len = reply.u32At(16);
        if (value_len == 0 or reply.extra.len < value_len) return null;
        if (value_len > self.clipboard_capacity.received_text_byte_count) {
            return error.TransferTooLarge;
        }
        const text = try allocator.alloc(u8, value_len);
        @memcpy(text, reply.extra[0..value_len]);
        return text;
    }

    pub fn setClipboardText(self: *X11Backend, text: []const u8) clipboard.PublishError!void {
        try self.clipboard_source.replace(text);
        const request = self.connection.beginRequest();
        protocol.setSelectionOwner(request, self.window, self.atoms.clipboard) catch
            return error.Unexpected;
        self.connection.sendRequest() catch return error.Unexpected;
    }

    fn serveClipboardRequest(
        self: *X11Backend,
        selection: protocol.SelectionRequestEvent,
    ) void {
        if (selection.owner != self.window or selection.selection != self.atoms.clipboard) return;
        var property = protocol.atom_none;
        if (selection.property != protocol.atom_none) {
            const kind = clipboardReplyKind(
                selection.target,
                self.atoms.utf8_string,
                self.atoms.targets,
            );
            const published = if (kind) |reply| switch (reply) {
                .utf8 => result: {
                    self.changePropertyForWindow(
                        selection.requestor,
                        selection.property,
                        self.atoms.utf8_string,
                        8,
                        self.clipboard_source.text(),
                    ) catch break :result false;
                    break :result true;
                },
                .targets => result: {
                    var targets: [8]u8 = undefined;
                    std.mem.writeInt(u32, targets[0..4], self.atoms.targets, .little);
                    std.mem.writeInt(u32, targets[4..8], self.atoms.utf8_string, .little);
                    self.changePropertyForWindow(
                        selection.requestor,
                        selection.property,
                        self.atoms.atom,
                        32,
                        &targets,
                    ) catch break :result false;
                    break :result true;
                },
            } else false;
            if (published) property = selection.property;
        }
        const request = self.connection.beginRequest();
        protocol.sendSelectionNotify(request, .{
            .time = selection.time,
            .requestor = selection.requestor,
            .selection = selection.selection,
            .target = selection.target,
            .property = property,
        }) catch return;
        self.connection.sendRequest() catch {};
    }

    fn restoreClipboardWaitEvents(self: *X11Backend) void {
        for (self.clipboard_wait_events.retained()) |event| {
            self.connection.retainMessage(event) catch unreachable;
        }
        self.clipboard_wait_events.reset();
    }

    pub fn clipboardStatus(self: *const X11Backend) clipboard.Status {
        return clipboard.Status.combine(
            self.clipboard_wait_events.status(),
            self.clipboard_source.status(),
        );
    }

    pub fn x11StorageStatus(self: *const X11Backend) x11.Status {
        return self.connection.storageStatus();
    }

    pub fn waylandStorageStatus(_: *const X11Backend) WaylandStorageStatus {
        return .{};
    }

    pub fn nextPresentationOutcome(_: *X11Backend) ?PresentationOutcome {
        return null;
    }

    pub fn presentationStatus(_: *const X11Backend) PresentationStatus {
        return .unavailable;
    }

    pub fn presentationStorageStatus(self: *const X11Backend) PresentationStorageStatus {
        return .{
            .frame_capacity_rejection_count = self.packed_region.capacity_rejection_count,
            .empty_region_fallback_count = self.empty_region_fallback_count,
            .x11_pixmap_refusal_count = self.pixmap_refusal_count,
            .x11_direct_frame_count = self.direct_frame_count,
        };
    }

    pub fn droppedEventCount(self: *const X11Backend) u64 {
        return self.events.droppedEventCount();
    }

    fn changePropertyBytes(self: *X11Backend, property: u32, property_type: u32, format: u8, data: []const u8) !void {
        return self.changePropertyForWindow(self.window, property, property_type, format, data);
    }

    fn changePropertyForWindow(
        self: *X11Backend,
        target_window: u32,
        property: u32,
        property_type: u32,
        format: u8,
        data: []const u8,
    ) !void {
        const request = self.connection.beginRequest();
        try protocol.changeProperty(request, .{
            .window = target_window,
            .property = property,
            .property_type = property_type,
            .format = format,
            .data = data,
        });
        try self.connection.sendRequest();
    }
};

const ClipboardReplyKind = enum {
    utf8,
    targets,
};

fn clipboardReplyKind(
    target: u32,
    utf8_string: u32,
    targets: u32,
) ?ClipboardReplyKind {
    if (target == utf8_string) return .utf8;
    if (target == targets) return .targets;
    return null;
}

fn internAtoms(connection: *x11.Connection) !Atoms {
    return .{
        .wm_protocols = try connection.internAtom("WM_PROTOCOLS"),
        .wm_delete_window = try connection.internAtom("WM_DELETE_WINDOW"),
        .net_wm_name = try connection.internAtom("_NET_WM_NAME"),
        .utf8_string = try connection.internAtom("UTF8_STRING"),
        .wm_normal_hints = try connection.internAtom("WM_NORMAL_HINTS"),
        .wm_size_hints = try connection.internAtom("WM_SIZE_HINTS"),
        .wm_change_state = try connection.internAtom("WM_CHANGE_STATE"),
        .net_wm_state = try connection.internAtom("_NET_WM_STATE"),
        .net_wm_state_max_horz = try connection.internAtom("_NET_WM_STATE_MAXIMIZED_HORZ"),
        .net_wm_state_max_vert = try connection.internAtom("_NET_WM_STATE_MAXIMIZED_VERT"),
        .clipboard = try connection.internAtom("CLIPBOARD"),
        .windowing_selection = try connection.internAtom("WINDOWING_SELECTION"),
        .targets = try connection.internAtom("TARGETS"),
        .atom = 4,
    };
}

fn clampU16(value: u32) u16 {
    return if (value > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(value);
}

const PixelPacking = struct {
    endian: std.builtin.Endian,
    red_shift: u5,
    green_shift: u5,
    blue_shift: u5,
};

const PackedRegionStorage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    capacity_rejection_count: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        byte_count: usize,
    ) std.mem.Allocator.Error!PackedRegionStorage {
        std.debug.assert(byte_count > 0);
        return .{
            .allocator = allocator,
            .bytes = try allocator.alloc(u8, byte_count),
        };
    }

    fn deinit(self: *PackedRegionStorage) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn prepare(self: *PackedRegionStorage, byte_count: usize) error{CapacityExceeded}![]u8 {
        if (byte_count > self.bytes.len) {
            self.capacity_rejection_count +|= 1;
            return error.CapacityExceeded;
        }
        return self.bytes[0..byte_count];
    }
};

fn packRegionRgba8(rgba8: []const u8, frame_width: u32, out: []u8, region: PresentRegion, packing: PixelPacking) void {
    var y: u32 = 0;
    while (y < region.height) : (y += 1) {
        var x: u32 = 0;
        while (x < region.width) : (x += 1) {
            const source_index = (@as(usize, region.y + y) * @as(usize, frame_width) + @as(usize, region.x + x)) * 4;
            const target_index = (@as(usize, y) * @as(usize, region.width) + @as(usize, x)) * 4;
            packRgba8Pixel(rgba8[source_index..][0..4], out[target_index..][0..4], packing);
        }
    }
}

fn packRgba8Pixel(source: *const [4]u8, target: *[4]u8, packing: PixelPacking) void {
    const word = (@as(u32, source[0]) << packing.red_shift) |
        (@as(u32, source[1]) << packing.green_shift) |
        (@as(u32, source[2]) << packing.blue_shift);
    std.mem.writeInt(u32, target, word, packing.endian);
}

fn regionByteCount(region: PresentRegion) PresentError!usize {
    const pixels = std.math.mul(usize, @as(usize, region.width), @as(usize, region.height)) catch return error.UnsupportedFormat;
    return std.math.mul(usize, pixels, 4) catch return error.UnsupportedFormat;
}

fn maskShift(mask: u32, fallback: u5) u5 {
    if (mask == 0) return fallback;
    return @intCast(@ctz(mask));
}

fn modifiersFromState(state: u16) Modifier {
    return .{
        .shift = (state & protocol.state_mask.shift) != 0,
        .ctrl = (state & protocol.state_mask.control) != 0,
        .alt = (state & protocol.state_mask.mod1) != 0,
        .super = (state & protocol.state_mask.mod4) != 0,
    };
}

fn mouseButtonFromCode(code: u8) ?MouseButton {
    return switch (code) {
        1 => .left,
        2 => .middle,
        3 => .right,
        8 => .x1,
        9 => .x2,
        else => null,
    };
}

fn wheelFromButton(code: u8) ?[2]f32 {
    return switch (code) {
        4 => .{ 0, 1 },
        5 => .{ 0, -1 },
        6 => .{ -1, 0 },
        7 => .{ 1, 0 },
        else => null,
    };
}

fn cursorGlyph(shape: CursorShape) u16 {
    return switch (shape) {
        .default => 68,
        .resize_ns => 116,
        .resize_ew => 108,
        .resize_nwse => 134,
        .resize_nesw => 136,
    };
}

fn textFromKeysym(keysym: native_xkb.keysym.Keysym, buffer: *[4]u8) ?[]const u8 {
    const codepoint = native_xkb.keysym.codepoint(keysym) orelse return null;
    const len = std.unicode.utf8Encode(codepoint, buffer) catch return null;
    return buffer[0..len];
}

test "x11 connection capacity composes event and clipboard retention" {
    const defaults = try deriveConnectionCapacity(
        try event_module.Capacity.derive(.{}),
        try clipboard.Capacity.derive(.{}),
        protocol.maximum_request_byte_count,
        x11.default_reply_byte_count,
    );
    try std.testing.expectEqual(@as(usize, 320), defaults.retained_message_count);
    try std.testing.expectEqual(
        320 * @sizeOf(x11.Message),
        defaults.retained_message_bytes,
    );
    try std.testing.expectEqual(
        protocol.maximum_request_byte_count,
        defaults.request_byte_count,
    );
    try std.testing.expectEqual(x11.default_reply_byte_count, defaults.reply_byte_count);
    try std.testing.expectEqual(
        defaults.retained_message_bytes + defaults.request_byte_count + defaults.reply_byte_count,
        defaults.steady_requested_bytes,
    );
    try std.testing.expectEqual(
        defaults.steady_requested_bytes + defaults.initialization_scratch_byte_count,
        defaults.initialization_high_water_bytes,
    );

    const selected = try deriveConnectionCapacity(
        try event_module.Capacity.derive(.{ .retained_event_count = 2 }),
        try clipboard.Capacity.derive(.{
            .received_text_byte_count = 7,
            .published_text_byte_count = 1024,
            .retained_wait_event_count = 3,
        }),
        4096,
        protocol.maximum_keyboard_mapping_reply_byte_count,
    );
    try std.testing.expectEqual(@as(usize, 5), selected.retained_message_count);
    try std.testing.expectEqual(
        5 * @sizeOf(x11.Message),
        selected.retained_message_bytes,
    );
    try std.testing.expectEqual(@as(usize, 4096), selected.request_byte_count);
    try std.testing.expectEqual(
        protocol.maximum_keyboard_mapping_reply_byte_count,
        selected.reply_byte_count,
    );
    try std.testing.expectError(error.RequestStorageTooSmall, deriveConnectionCapacity(
        try event_module.Capacity.derive(.{}),
        try clipboard.Capacity.derive(.{
            .published_text_byte_count = 64,
        }),
        protocol.minimum_request_byte_count - 4,
        x11.default_reply_byte_count,
    ));
    try std.testing.expectError(error.RequestStorageUnaligned, deriveConnectionCapacity(
        try event_module.Capacity.derive(.{}),
        try clipboard.Capacity.derive(.{
            .published_text_byte_count = 32,
        }),
        89,
        x11.default_reply_byte_count,
    ));
    try std.testing.expectError(error.ReplyStorageTooSmall, deriveConnectionCapacity(
        try event_module.Capacity.derive(.{}),
        try clipboard.Capacity.derive(.{}),
        protocol.maximum_request_byte_count,
        x11.default_reply_byte_count - 4,
    ));
}

test "x11 clipboard reply plan accepts utf8 and targets only" {
    try std.testing.expectEqual(
        ClipboardReplyKind.utf8,
        clipboardReplyKind(11, 11, 12).?,
    );
    try std.testing.expectEqual(
        ClipboardReplyKind.targets,
        clipboardReplyKind(12, 11, 12).?,
    );
    try std.testing.expect(clipboardReplyKind(13, 11, 12) == null);
}

test "keysym text conversion uses XKB Unicode semantics" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("a", textFromKeysym(@fromBackingInt('a'), &buffer).?);
    try std.testing.expectEqualStrings("é", textFromKeysym(@fromBackingInt(0xe9), &buffer).?);
    try std.testing.expectEqualStrings("λ", textFromKeysym(@fromBackingInt(0x07eb), &buffer).?);
    try std.testing.expectEqualStrings("7", textFromKeysym(@fromBackingInt(0xffb7), &buffer).?);
    try std.testing.expect(textFromKeysym(@fromBackingInt(0xffe1), &buffer) == null);
}

test "modifier state maps to windowing modifiers" {
    const modifiers = modifiersFromState(protocol.state_mask.shift | protocol.state_mask.control);
    try std.testing.expect(modifiers.shift);
    try std.testing.expect(modifiers.ctrl);
    try std.testing.expect(!modifiers.alt);
    try std.testing.expect(!modifiers.super);
}

test "wheel buttons map to scroll deltas and skip button events" {
    try std.testing.expectEqual([2]f32{ 0, 1 }, wheelFromButton(4).?);
    try std.testing.expectEqual([2]f32{ 0, -1 }, wheelFromButton(5).?);
    try std.testing.expect(wheelFromButton(1) == null);
    try std.testing.expectEqual(MouseButton.left, mouseButtonFromCode(1).?);
    try std.testing.expectEqual(MouseButton.x2, mouseButtonFromCode(9).?);
}

test "x11 rgba packing reads rectangular regions from retained frame" {
    const width: u32 = 4;
    const height: u32 = 3;
    var frame: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            frame[offset + 0] = @intCast(10 + x);
            frame[offset + 1] = @intCast(20 + y);
            frame[offset + 2] = @intCast(30 + x + y);
            frame[offset + 3] = 0xFF;
        }
    }

    const region = PresentRegion{ .x = 1, .y = 1, .width = 2, .height = 2 };
    var packed_pixels: [2 * 2 * 4]u8 = undefined;
    packRegionRgba8(&frame, width, &packed_pixels, region, .{
        .endian = .little,
        .red_shift = 16,
        .green_shift = 8,
        .blue_shift = 0,
    });

    for (0..region.height) |row| {
        for (0..region.width) |column| {
            const word = std.mem.readInt(u32, packed_pixels[(row * region.width + column) * 4 ..][0..4], .little);
            const source_x: u8 = @intCast(region.x + column);
            const source_y: u8 = @intCast(region.y + row);
            try std.testing.expectEqual(@as(u8, 10 + source_x), @as(u8, @truncate(word >> 16)));
            try std.testing.expectEqual(@as(u8, 20 + source_y), @as(u8, @truncate(word >> 8)));
            try std.testing.expectEqual(@as(u8, 30 + source_x + source_y), @as(u8, @truncate(word)));
        }
    }
}

test "x11 packed region storage admits its exact bound and rejects max plus one" {
    var storage = try PackedRegionStorage.init(std.testing.allocator, 4096);
    defer storage.deinit();

    const active = try storage.prepare(4096);
    @memset(active, 0xA5);
    _ = try storage.prepare(1024);
    try std.testing.expectError(error.CapacityExceeded, storage.prepare(4097));
    try std.testing.expectEqual(@as(u64, 1), storage.capacity_rejection_count);
    try std.testing.expectEqual(@as(u8, 0xA5), storage.bytes[4095]);
    storage.capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(error.CapacityExceeded, storage.prepare(4097));
    try std.testing.expectEqual(std.math.maxInt(u64), storage.capacity_rejection_count);
}

test "x11 packed region storage reports acquisition failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        PackedRegionStorage.init(failing.allocator(), 4096),
    );
}

test "live window presents pixels the server reads back" {
    if (comptime sys.capabilities.current.os != .linux) return error.SkipZigTest;
    if (sys.env.get("DISPLAY") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend: X11Backend = undefined;
    backend.init(allocator, .{
        .title = "windowing-x11-live",
        .width = 64,
        .height = 32,
        .backend = .x11,
    }) catch |err| switch (err) {
        error.ConnectionFailed => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();

    try std.testing.expect(backend.window != 0);
    const native = backend.nativeSurface();
    try std.testing.expectEqual(surface.Kind.x11, native.kind());
    try std.testing.expectEqual(backend.window, native.x11.window);
    try std.testing.expectEqual(backend.connection.setup.visual, native.x11.visual);
    try std.testing.expectEqual(@as(usize, 64 * 32), native.extent().pixelCount().?);
    var mapped_keycodes: usize = 0;
    for (backend.keysyms) |columns| {
        if (columns[0] != 0) mapped_keycodes += 1;
    }
    try std.testing.expect(mapped_keycodes > 0);

    var iterator = try backend.pollEvents();
    while (iterator.next()) |_| {}

    const width: u32 = 64;
    const height: u32 = 32;
    const frame = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(frame);
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            frame[offset + 0] = @intCast(x * 4);
            frame[offset + 1] = @intCast(y * 8);
            frame[offset + 2] = 0x40;
            frame[offset + 3] = 0xFF;
        }
    }
    try backend.presentRgba8(frame, width, height);

    const request = backend.connection.beginRequest();
    try protocol.getImage(request, .{
        .drawable = backend.window,
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    });
    try backend.connection.sendRequest();
    const reply = try backend.connection.waitReply();

    try std.testing.expect(reply.extra.len >= width * height * 4);
    const endian: std.builtin.Endian = if (backend.connection.setup.image_byte_order_msb) .big else .little;
    var mismatches: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            const word = std.mem.readInt(u32, reply.extra[offset..][0..4], endian);
            const red: u8 = @truncate(word >> backend.red_shift);
            const green: u8 = @truncate(word >> backend.green_shift);
            const blue: u8 = @truncate(word >> backend.blue_shift);
            if (red != frame[offset + 0] or green != frame[offset + 1] or blue != frame[offset + 2]) {
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);

    const dirty = PresentRegion{ .x = 11, .y = 7, .width = 9, .height = 6 };
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            const inside = x >= dirty.x and x < dirty.x + dirty.width and y >= dirty.y and y < dirty.y + dirty.height;
            if (inside) {
                frame[offset + 0] = 0xE1;
                frame[offset + 1] = 0x72;
                frame[offset + 2] = 0x29;
            } else {
                frame[offset + 0] = 0x11;
                frame[offset + 1] = 0x22;
                frame[offset + 2] = 0x33;
            }
            frame[offset + 3] = 0xFF;
        }
    }
    try backend.presentRgba8Region(frame, width, height, dirty);

    const region_request = backend.connection.beginRequest();
    try protocol.getImage(region_request, .{
        .drawable = backend.window,
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    });
    try backend.connection.sendRequest();
    const region_reply = try backend.connection.waitReply();

    var region_mismatches: usize = 0;
    var outside_mutations: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            const word = std.mem.readInt(u32, region_reply.extra[offset..][0..4], endian);
            const red: u8 = @truncate(word >> backend.red_shift);
            const green: u8 = @truncate(word >> backend.green_shift);
            const blue: u8 = @truncate(word >> backend.blue_shift);
            const inside = x >= dirty.x and x < dirty.x + dirty.width and y >= dirty.y and y < dirty.y + dirty.height;
            if (inside) {
                if (red != 0xE1 or green != 0x72 or blue != 0x29) region_mismatches += 1;
            } else if (red != @as(u8, @intCast(x * 4)) or green != @as(u8, @intCast(y * 8)) or blue != 0x40) {
                outside_mutations += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), region_mismatches);
    try std.testing.expectEqual(@as(usize, 0), outside_mutations);

    backend.setTitle("windowing-x11-live-renamed");
    backend.setCursor(.resize_ew);
    _ = backend.isMaximized();
    var post = try backend.pollEvents();
    while (post.next()) |_| {}

    var keycode_w: u8 = 0;
    for (backend.keysyms, 0..) |columns, code| {
        if (columns[0] == 'w') {
            keycode_w = @intCast(code);
            break;
        }
    }
    try std.testing.expect(keycode_w != 0);

    var raw = @as([protocol.message_length]u8, @splat(0));
    raw[0] = @backingInt(protocol.EventCode.key_press);
    raw[1] = keycode_w;
    std.mem.writeInt(u32, raw[12..16], backend.window, .little);
    const inject = backend.connection.beginRequest();
    try protocol.sendEvent(
        inject,
        backend.window,
        protocol.event_mask.key_press,
        &raw,
    );
    try backend.connection.sendRequest();

    var saw_key_press = false;
    var attempts: usize = 0;
    while (attempts < 20 and !saw_key_press) : (attempts += 1) {
        _ = try backend.connection.waitReadable(50);
        var pump = try backend.pollEvents();
        while (pump.next()) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.key == .w) saw_key_press = true;
                },
                else => {},
            }
        }
        if (backend.input.isKeyDown(.w)) break;
    }
    try std.testing.expect(saw_key_press);
    try std.testing.expect(backend.input.isKeyDown(.w));
}

const WireFixture = struct {
    sockets: [2]sys.net.Socket,
    request_storage: [4096]u8 = undefined,
    retained: [2]x11.connection.Message = undefined,
    backend: X11Backend = undefined,

    fn init(self: *WireFixture) !void {
        self.sockets = try sys.net.socketPairUnixStream();
        errdefer sys.net.close(self.sockets[0]);
        errdefer sys.net.close(self.sockets[1]);
        var setup: protocol.Setup = std.mem.zeroes(protocol.Setup);
        setup.root_depth = 24;
        setup.resource_id_base = 0x100;
        setup.resource_id_mask = 0xff;
        self.backend = .{
            .connection = .{
                .allocator = std.testing.allocator,
                .target = undefined,
                .stream = sys.net.Stream.initFd(self.sockets[1]),
                .setup = setup,
                .screen = 0,
                .retained_messages = .{ .allocator = std.testing.allocator, .items = &self.retained },
                .request_storage = &self.request_storage,
                .request_scratch = protocol.Request.init(&self.request_storage, self.request_storage.len),
                .reply_storage = &.{},
            },
            .window = 1,
            .gc = 2,
            .atoms = undefined,
            .width = 4,
            .height = 4,
            .input = undefined,
            .gamepads = undefined,
            .clipboard_capacity = undefined,
            .clipboard_source = undefined,
            .clipboard_wait_events = undefined,
            .events = undefined,
            .packed_region = try PackedRegionStorage.init(std.testing.allocator, 64),
        };
    }

    fn deinit(self: *WireFixture) void {
        self.backend.packed_region.deinit();
        sys.net.close(self.sockets[0]);
        sys.net.close(self.sockets[1]);
    }

    fn barrier(self: *WireFixture) !void {
        var reply: x11.connection.Message = @splat(0);
        reply[0] = 1;
        std.mem.writeInt(u16, reply[2..4], self.backend.connection.nextRequestSequence() +% 1, .little);
        try sys.net.Stream.initFd(self.sockets[0]).writeAll(&reply);
    }

    fn requests(self: *WireFixture, out: []u8) ![]const u8 {
        const stream = sys.net.Stream.initFd(self.sockets[0]);
        var count: usize = 0;
        while (try sys.net.pollReadable(stream.handle, 0)) {
            if (count == out.len) return error.TestUnexpectedResult;
            const n = try stream.read(out[count..]);
            if (n == 0) return error.TestUnexpectedResult;
            count += n;
        }
        return out[0..count];
    }
};

fn wireOpcodes(bytes: []const u8, out: []u8) ![]const u8 {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < bytes.len) {
        try std.testing.expect(bytes.len - offset >= 4);
        const length = @as(usize, std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little)) * 4;
        try std.testing.expect(length >= 4);
        try std.testing.expect(length <= bytes.len - offset);
        try std.testing.expect(count < out.len);
        out[count] = bytes[offset];
        count += 1;
        offset += length;
    }
    return out[0..count];
}

test "X11 frame uploads every region then publishes once and acquires before releasing on resize" {
    var fixture: WireFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var wire: [1024]u8 = undefined;
    var opcodes: [16]u8 = undefined;
    var pixels: [64]u8 = @splat(0x31);
    try fixture.barrier();
    try std.testing.expectEqual(@as(u64, 1), try fixture.backend.presentRgba8Frame(&pixels, 4, 4, &.{}));
    const first = try fixture.requests(&wire);
    try std.testing.expectEqualSlices(u8, &.{ 53, 43, 72, 62 }, try wireOpcodes(first, &opcodes));
    const old = fixture.backend.pixmap.?.id;
    try std.testing.expectEqual(old, std.mem.readInt(u32, first[24..28], .little));
    for (0..16) |index| try std.testing.expectEqualSlices(u8, &.{ 0x31, 0x31, 0x31, 0 }, first[44 + index * 4 ..][0..4]);
    const dirty = [_]PresentRegion{ .{ .width = 1, .height = 1 }, .{ .x = 3, .y = 3, .width = 1, .height = 1 } };
    pixels[0] = 90;
    pixels[60] = 80;
    try std.testing.expectEqual(@as(u64, 2), try fixture.backend.presentRgba8Frame(&pixels, 4, 4, &dirty));
    const second = try fixture.requests(&wire);
    try std.testing.expectEqualSlices(u8, &.{ 72, 72, 62 }, try wireOpcodes(second, &opcodes));
    try std.testing.expectEqualSlices(u8, &.{ 0x31, 0x31, 90, 0 }, second[24..28]);
    try std.testing.expectEqualSlices(u8, &.{ 0x31, 0x31, 80, 0 }, second[52..56]);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, second[44..46], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, second[46..48], .little));
    const copy = second[second.len - 28 ..];
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, copy[24..26], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, copy[26..28], .little));
    try std.testing.expectEqual(old, std.mem.readInt(u32, copy[4..8], .little));
    try fixture.backend.presentRgba8Region(&pixels, 4, 4, dirty[0]);
    try std.testing.expectEqualSlices(u8, &.{ 72, 62 }, try wireOpcodes(try fixture.requests(&wire), &opcodes));
    try fixture.barrier();
    try std.testing.expectEqual(@as(u64, 4), try fixture.backend.presentRgba8Frame(&pixels, 8, 2, &.{}));
    const resize = try fixture.requests(&wire);
    try std.testing.expectEqualSlices(u8, &.{ 53, 43, 54, 72, 62 }, try wireOpcodes(resize, &opcodes));
    try std.testing.expectEqual(old, std.mem.readInt(u32, resize[24..28], .little));
    try std.testing.expect(fixture.backend.pixmap.?.id != old);
}

test "X11 matched BadAlloc survives retained overflow and pending frames use direct upload" {
    var fixture: WireFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const peer = sys.net.Stream.initFd(fixture.sockets[0]);
    var refusal: x11.connection.Message = @splat(0);
    refusal[1] = 11;
    refusal[10] = 53;
    std.mem.writeInt(u16, refusal[2..4], fixture.backend.connection.nextRequestSequence(), .little);
    std.mem.writeInt(u32, refusal[4..8], 0xdeadbeef, .little);
    try peer.writeAll(&refusal);
    var event: x11.connection.Message = @splat(0);
    event[0] = @backingInt(protocol.EventCode.configure_notify);
    for (0..3) |_| try peer.writeAll(&event);
    try fixture.barrier();
    const pixels: [64]u8 = @splat(0x42);
    const dirty = [_]PresentRegion{.{ .x = 1, .y = 1, .width = 1, .height = 1 }};
    try std.testing.expectEqual(@as(u64, 1), try fixture.backend.presentRgba8Frame(&pixels, 4, 4, &dirty));
    try std.testing.expect(fixture.backend.acquisition != null);
    try std.testing.expectEqual(@as(u64, 1), fixture.backend.x11StorageStatus().retained_message_capacity_rejection_count);
    try std.testing.expectEqual(@as(u64, 1), fixture.backend.direct_frame_count);
    var wire: [1024]u8 = undefined;
    var opcodes: [16]u8 = undefined;
    const first = try fixture.requests(&wire);
    try std.testing.expectEqualSlices(u8, &.{ 53, 43, 72 }, try wireOpcodes(first, &opcodes));
    try std.testing.expectEqual(@as(usize, 108), first.len);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, first[32..34], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, first[34..36], .little));
    for (0..16) |index| try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x42, 0x42, 0 }, first[44 + index * 4 ..][0..4]);
    var retained_events: usize = 0;
    while (try fixture.backend.connection.nextMessage()) |raw| {
        if (try fixture.backend.observeAcquisition(raw)) continue;
        try std.testing.expectEqual(event, raw);
        retained_events += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), retained_events);
    try std.testing.expect(fixture.backend.acquisition == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.backend.pixmap_refusal_count);
    try std.testing.expectEqual(@as(u64, 2), try fixture.backend.presentRgba8Frame(&pixels, 4, 4, &dirty));
    const second = try fixture.requests(&wire);
    try std.testing.expectEqualSlices(u8, &.{72}, try wireOpcodes(second, &opcodes));
    try std.testing.expectEqual(@as(usize, 88), second.len);
    try std.testing.expectEqual(@as(u64, 2), fixture.backend.direct_frame_count);
    std.mem.writeInt(u16, refusal[2..4], fixture.backend.connection.nextRequestSequence(), .little);
    try peer.writeAll(&refusal);
    try fixture.barrier();
    try std.testing.expectEqual(@as(u64, 3), try fixture.backend.presentRgba8Frame(&pixels, 8, 2, &dirty));
    const resized = try fixture.requests(&wire);
    try std.testing.expectEqualSlices(u8, &.{ 53, 43, 72 }, try wireOpcodes(resized, &opcodes));
    try std.testing.expectEqual(@as(usize, 108), resized.len);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, resized[32..34], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, resized[34..36], .little));
    for (0..16) |index| try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x42, 0x42, 0 }, resized[44 + index * 4 ..][0..4]);
    try std.testing.expectEqual(@as(u64, 3), fixture.backend.direct_frame_count);
    try std.testing.expectEqual(@as(u64, 2), fixture.backend.pixmap_refusal_count);
}
