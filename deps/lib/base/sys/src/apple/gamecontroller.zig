const std = @import("std");
const builtin = @import("builtin");
const apple = @import("root.zig");

const objc = apple.objc;

pub const supported = builtin.os.tag == .macos;

pub const Button = enum {
    a,
    b,
    x,
    y,
    menu,
    options,
    home,
    left_shoulder,
    right_shoulder,
    left_thumbstick,
    right_thumbstick,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
};

pub const Axis = enum {
    left_thumbstick_x,
    left_thumbstick_y,
    right_thumbstick_x,
    right_thumbstick_y,
    left_trigger,
    right_trigger,
};

pub const Controller = struct {
    object: objc.Id,

    pub fn retain(self: Controller) Controller {
        return .{ .object = objc.retain(self.object) };
    }

    pub fn release(self: Controller) void {
        objc.release(self.object);
    }

    pub fn eql(self: Controller, other: Controller) bool {
        return self.object == other.object;
    }
};

pub const Profile = struct {
    object: objc.Id,
};

pub const ControllerList = struct {
    autorelease_pool: objc.AutoreleasePool,
    array: objc.Id,
    count: usize,
    object_at_index: objc.SEL,

    pub fn deinit(self: *ControllerList) void {
        objc.release(self.array);
        self.autorelease_pool.deinit();
        self.* = undefined;
    }

    pub fn at(self: *const ControllerList, index: usize) Controller {
        std.debug.assert(index < self.count);
        return .{ .object = objc.send(
            objc.Id,
            self.array,
            self.object_at_index,
            .{index},
        ) };
    }
};

const Selectors = struct {
    controllers: objc.SEL,
    controller_with_extended_gamepad: objc.SEL,
    count: objc.SEL,
    object_at_index: objc.SEL,
    extended_gamepad: objc.SEL,
    vendor_name: objc.SEL,
    utf8_string: objc.SEL,
    responds_to_selector: objc.SEL,
    is_pressed: objc.SEL,
    value: objc.SEL,
    set_value: objc.SEL,
    set_value_for_x_axis_y_axis: objc.SEL,
    button_a: objc.SEL,
    button_b: objc.SEL,
    button_x: objc.SEL,
    button_y: objc.SEL,
    button_menu: objc.SEL,
    button_options: objc.SEL,
    button_home: objc.SEL,
    left_shoulder: objc.SEL,
    right_shoulder: objc.SEL,
    left_trigger: objc.SEL,
    right_trigger: objc.SEL,
    left_thumbstick: objc.SEL,
    right_thumbstick: objc.SEL,
    left_thumbstick_button: objc.SEL,
    right_thumbstick_button: objc.SEL,
    dpad: objc.SEL,
    x_axis: objc.SEL,
    y_axis: objc.SEL,
    up: objc.SEL,
    down: objc.SEL,
    left: objc.SEL,
    right: objc.SEL,

    fn init() Selectors {
        return .{
            .controllers = objc.selector("controllers"),
            .controller_with_extended_gamepad = objc.selector("controllerWithExtendedGamepad"),
            .count = objc.selector("count"),
            .object_at_index = objc.selector("objectAtIndex:"),
            .extended_gamepad = objc.selector("extendedGamepad"),
            .vendor_name = objc.selector("vendorName"),
            .utf8_string = objc.selector("UTF8String"),
            .responds_to_selector = objc.selector("respondsToSelector:"),
            .is_pressed = objc.selector("isPressed"),
            .value = objc.selector("value"),
            .set_value = objc.selector("setValue:"),
            .set_value_for_x_axis_y_axis = objc.selector("setValueForXAxis:yAxis:"),
            .button_a = objc.selector("buttonA"),
            .button_b = objc.selector("buttonB"),
            .button_x = objc.selector("buttonX"),
            .button_y = objc.selector("buttonY"),
            .button_menu = objc.selector("buttonMenu"),
            .button_options = objc.selector("buttonOptions"),
            .button_home = objc.selector("buttonHome"),
            .left_shoulder = objc.selector("leftShoulder"),
            .right_shoulder = objc.selector("rightShoulder"),
            .left_trigger = objc.selector("leftTrigger"),
            .right_trigger = objc.selector("rightTrigger"),
            .left_thumbstick = objc.selector("leftThumbstick"),
            .right_thumbstick = objc.selector("rightThumbstick"),
            .left_thumbstick_button = objc.selector("leftThumbstickButton"),
            .right_thumbstick_button = objc.selector("rightThumbstickButton"),
            .dpad = objc.selector("dpad"),
            .x_axis = objc.selector("xAxis"),
            .y_axis = objc.selector("yAxis"),
            .up = objc.selector("up"),
            .down = objc.selector("down"),
            .left = objc.selector("left"),
            .right = objc.selector("right"),
        };
    }
};

pub const Runtime = struct {
    controller_class: objc.Id,
    selectors: Selectors,

    pub fn init() ?Runtime {
        if (comptime !supported) return null;
        return .{
            .controller_class = objc.class("GCController") orelse return null,
            .selectors = .init(),
        };
    }

    pub fn controllers(self: *const Runtime) ControllerList {
        const autorelease_pool = objc.AutoreleasePool.init();
        const borrowed = objc.send(
            objc.Id,
            self.controller_class,
            self.selectors.controllers,
            .{},
        );
        const array = objc.retain(borrowed);
        return .{
            .autorelease_pool = autorelease_pool,
            .array = array,
            .count = objc.send(usize, array, self.selectors.count, .{}),
            .object_at_index = self.selectors.object_at_index,
        };
    }

    pub fn extendedGamepad(self: *const Runtime, controller: Controller) ?Profile {
        const object = objc.send(
            ?objc.Id,
            controller.object,
            self.selectors.extended_gamepad,
            .{},
        ) orelse return null;
        return .{ .object = object };
    }

    pub fn controllerName(
        self: *const Runtime,
        controller: Controller,
    ) ?[*:0]const u8 {
        const string = objc.send(
            ?objc.Id,
            controller.object,
            self.selectors.vendor_name,
            .{},
        ) orelse return null;
        return objc.send(?[*:0]const u8, string, self.selectors.utf8_string, .{});
    }

    pub fn buttonPressed(
        self: *const Runtime,
        profile: Profile,
        button: Button,
    ) bool {
        const object = self.buttonObject(profile, button) orelse return false;
        return objc.isTrue(objc.send(objc.BOOL, object, self.selectors.is_pressed, .{}));
    }

    pub fn axisValue(self: *const Runtime, profile: Profile, axis: Axis) f32 {
        const object = self.axisObject(profile, axis) orelse return 0;
        return objc.send(f32, object, self.selectors.value, .{});
    }

    pub fn createRetainedSnapshot(self: *const Runtime) ?Controller {
        if (!self.responds(
            self.controller_class,
            self.selectors.controller_with_extended_gamepad,
        )) return null;
        const borrowed = objc.send(
            ?objc.Id,
            self.controller_class,
            self.selectors.controller_with_extended_gamepad,
            .{},
        ) orelse return null;
        return (Controller{ .object = borrowed }).retain();
    }

    pub fn setButtonValue(
        self: *const Runtime,
        profile: Profile,
        button: Button,
        value: f32,
    ) bool {
        std.debug.assert(value >= 0);
        std.debug.assert(value <= 1);
        const is_direction = switch (button) {
            .dpad_up, .dpad_down, .dpad_left, .dpad_right => true,
            else => false,
        };
        if (is_direction) return self.setDirectionButtonValue(profile, button, value);
        const object = self.buttonObject(profile, button) orelse return false;
        if (!self.responds(object, self.selectors.set_value)) return false;
        objc.send(void, object, self.selectors.set_value, .{value});
        return true;
    }

    pub fn setAxisValue(
        self: *const Runtime,
        profile: Profile,
        axis: Axis,
        value: f32,
    ) bool {
        std.debug.assert(value >= -1);
        std.debug.assert(value <= 1);
        if (axis == .left_trigger or axis == .right_trigger) {
            std.debug.assert(value >= 0);
        }
        const object = self.axisObject(profile, axis) orelse return false;
        if (!self.responds(object, self.selectors.set_value)) return false;
        objc.send(void, object, self.selectors.set_value, .{value});
        return true;
    }

    pub fn setDirectionPadValue(
        self: *const Runtime,
        profile: Profile,
        x: f32,
        y: f32,
    ) bool {
        std.debug.assert(x >= -1);
        std.debug.assert(x <= 1);
        std.debug.assert(y >= -1);
        std.debug.assert(y <= 1);
        const dpad = objc.send(?objc.Id, profile.object, self.selectors.dpad, .{}) orelse
            return false;
        if (!self.responds(dpad, self.selectors.set_value_for_x_axis_y_axis)) return false;
        objc.send(
            void,
            dpad,
            self.selectors.set_value_for_x_axis_y_axis,
            .{ x, y },
        );
        return true;
    }

    fn setDirectionButtonValue(
        self: *const Runtime,
        profile: Profile,
        button: Button,
        value: f32,
    ) bool {
        const dpad = objc.send(?objc.Id, profile.object, self.selectors.dpad, .{}) orelse
            return false;
        const x_axis = objc.send(?objc.Id, dpad, self.selectors.x_axis, .{}) orelse return false;
        const y_axis = objc.send(?objc.Id, dpad, self.selectors.y_axis, .{}) orelse return false;
        var x = objc.send(f32, x_axis, self.selectors.value, .{});
        var y = objc.send(f32, y_axis, self.selectors.value, .{});
        switch (button) {
            .dpad_up => if (y > 0 or value > 0) {
                y = value;
            },
            .dpad_down => if (y < 0 or value > 0) {
                y = -value;
            },
            .dpad_left => if (x < 0 or value > 0) {
                x = -value;
            },
            .dpad_right => if (x > 0 or value > 0) {
                x = value;
            },
            else => unreachable,
        }
        return self.setDirectionPadValue(profile, x, y);
    }

    fn buttonObject(
        self: *const Runtime,
        profile: Profile,
        button: Button,
    ) ?objc.Id {
        return switch (button) {
            .dpad_up => self.directionButton(profile, self.selectors.up),
            .dpad_down => self.directionButton(profile, self.selectors.down),
            .dpad_left => self.directionButton(profile, self.selectors.left),
            .dpad_right => self.directionButton(profile, self.selectors.right),
            else => self.directButton(profile, button),
        };
    }

    fn directButton(
        self: *const Runtime,
        profile: Profile,
        button: Button,
    ) ?objc.Id {
        const selector = self.directButtonSelector(button) orelse return null;
        if (isOptionalButton(button) and !self.responds(profile.object, selector)) return null;
        return objc.send(?objc.Id, profile.object, selector, .{});
    }

    fn directionButton(
        self: *const Runtime,
        profile: Profile,
        selector: objc.SEL,
    ) ?objc.Id {
        const dpad = objc.send(?objc.Id, profile.object, self.selectors.dpad, .{}) orelse
            return null;
        return objc.send(?objc.Id, dpad, selector, .{});
    }

    fn axisObject(self: *const Runtime, profile: Profile, axis: Axis) ?objc.Id {
        const direct = switch (axis) {
            .left_trigger => self.selectors.left_trigger,
            .right_trigger => self.selectors.right_trigger,
            else => null,
        };
        if (direct) |selector| return objc.send(?objc.Id, profile.object, selector, .{});
        const stick_selector = switch (axis) {
            .left_thumbstick_x, .left_thumbstick_y => self.selectors.left_thumbstick,
            .right_thumbstick_x, .right_thumbstick_y => self.selectors.right_thumbstick,
            else => unreachable,
        };
        const stick = objc.send(?objc.Id, profile.object, stick_selector, .{}) orelse return null;
        const axis_selector = switch (axis) {
            .left_thumbstick_x, .right_thumbstick_x => self.selectors.x_axis,
            .left_thumbstick_y, .right_thumbstick_y => self.selectors.y_axis,
            else => unreachable,
        };
        return objc.send(?objc.Id, stick, axis_selector, .{});
    }

    fn directButtonSelector(self: *const Runtime, button: Button) ?objc.SEL {
        return switch (button) {
            .a => self.selectors.button_a,
            .b => self.selectors.button_b,
            .x => self.selectors.button_x,
            .y => self.selectors.button_y,
            .menu => self.selectors.button_menu,
            .options => self.selectors.button_options,
            .home => self.selectors.button_home,
            .left_shoulder => self.selectors.left_shoulder,
            .right_shoulder => self.selectors.right_shoulder,
            .left_thumbstick => self.selectors.left_thumbstick_button,
            .right_thumbstick => self.selectors.right_thumbstick_button,
            .dpad_up, .dpad_down, .dpad_left, .dpad_right => null,
        };
    }

    fn responds(self: *const Runtime, object: objc.Id, selector: objc.SEL) bool {
        return objc.isTrue(objc.send(
            objc.BOOL,
            object,
            self.selectors.responds_to_selector,
            .{selector},
        ));
    }
};

fn isOptionalButton(button: Button) bool {
    return switch (button) {
        .menu, .options, .home, .left_thumbstick, .right_thumbstick => true,
        else => false,
    };
}

test "GameController snapshot round-trips raw extended inputs" {
    if (comptime !supported) return error.SkipZigTest;

    const runtime = Runtime.init().?;
    const controller = runtime.createRetainedSnapshot().?;
    defer controller.release();
    const profile = runtime.extendedGamepad(controller).?;

    try std.testing.expect(runtime.setButtonValue(profile, .a, 1));
    try std.testing.expect(runtime.buttonPressed(profile, .a));
    try std.testing.expect(runtime.setDirectionPadValue(profile, 0, 1));
    try std.testing.expect(runtime.buttonPressed(profile, .dpad_up));
    try std.testing.expect(runtime.setAxisValue(profile, .left_thumbstick_x, 0.75));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.75),
        runtime.axisValue(profile, .left_thumbstick_x),
        0.001,
    );
    try std.testing.expect(runtime.setAxisValue(profile, .right_trigger, 0.5));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        runtime.axisValue(profile, .right_trigger),
        0.001,
    );
}

test "GameController connected list has valid borrowed entries" {
    if (comptime !supported) return error.SkipZigTest;

    const runtime = Runtime.init().?;
    for (0..64) |_| {
        var controllers = runtime.controllers();
        defer controllers.deinit();
        for (0..controllers.count) |index| {
            try std.testing.expect(controllers.at(index).object != objc.nil);
        }
    }
}
