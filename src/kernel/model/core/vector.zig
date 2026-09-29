const builder = @import("builder.zig");

pub const Vec2 = struct {
    x: builder.Value,
    y: builder.Value,

    pub fn init(x: builder.Value, y: builder.Value) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn splat(value: builder.Value) Vec2 {
        return .{ .x = value, .y = value };
    }

    pub fn add(self: Vec2, k: anytype, rhs: Vec2) !Vec2 {
        return .{
            .x = try k.add(self.x, rhs.x),
            .y = try k.add(self.y, rhs.y),
        };
    }

    pub fn sub(self: Vec2, k: anytype, rhs: Vec2) !Vec2 {
        return .{
            .x = try k.sub(self.x, rhs.x),
            .y = try k.sub(self.y, rhs.y),
        };
    }

    pub fn mul(self: Vec2, k: anytype, rhs: Vec2) !Vec2 {
        return .{
            .x = try k.mul(self.x, rhs.x),
            .y = try k.mul(self.y, rhs.y),
        };
    }

    pub fn scale(self: Vec2, k: anytype, rhs: builder.Value) !Vec2 {
        return .{
            .x = try k.mul(self.x, rhs),
            .y = try k.mul(self.y, rhs),
        };
    }

    pub fn abs(self: Vec2, k: anytype) !Vec2 {
        return .{
            .x = try k.abs(self.x),
            .y = try k.abs(self.y),
        };
    }

    pub fn min(self: Vec2, k: anytype, rhs: Vec2) !Vec2 {
        return .{
            .x = try k.min(self.x, rhs.x),
            .y = try k.min(self.y, rhs.y),
        };
    }

    pub fn max(self: Vec2, k: anytype, rhs: Vec2) !Vec2 {
        return .{
            .x = try k.max(self.x, rhs.x),
            .y = try k.max(self.y, rhs.y),
        };
    }

    pub fn dot(self: Vec2, k: anytype, rhs: Vec2) !builder.Value {
        const x_product = try k.mul(self.x, rhs.x);
        const y_product = try k.mul(self.y, rhs.y);
        return k.add(x_product, y_product);
    }

    pub fn lengthSquared(self: Vec2, k: anytype) !builder.Value {
        return self.dot(k, self);
    }

    pub fn length(self: Vec2, k: anytype) !builder.Value {
        return k.sqrt(try self.lengthSquared(k));
    }

    pub fn distance(self: Vec2, k: anytype, rhs: Vec2) !builder.Value {
        return (try self.sub(k, rhs)).length(k);
    }
};

pub const Vec3 = struct {
    x: builder.Value,
    y: builder.Value,
    z: builder.Value,

    pub fn init(x: builder.Value, y: builder.Value, z: builder.Value) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn splat(value: builder.Value) Vec3 {
        return .{ .x = value, .y = value, .z = value };
    }

    pub fn add(self: Vec3, k: anytype, rhs: Vec3) !Vec3 {
        return .{
            .x = try k.add(self.x, rhs.x),
            .y = try k.add(self.y, rhs.y),
            .z = try k.add(self.z, rhs.z),
        };
    }

    pub fn sub(self: Vec3, k: anytype, rhs: Vec3) !Vec3 {
        return .{
            .x = try k.sub(self.x, rhs.x),
            .y = try k.sub(self.y, rhs.y),
            .z = try k.sub(self.z, rhs.z),
        };
    }

    pub fn mul(self: Vec3, k: anytype, rhs: Vec3) !Vec3 {
        return .{
            .x = try k.mul(self.x, rhs.x),
            .y = try k.mul(self.y, rhs.y),
            .z = try k.mul(self.z, rhs.z),
        };
    }

    pub fn scale(self: Vec3, k: anytype, rhs: builder.Value) !Vec3 {
        return .{
            .x = try k.mul(self.x, rhs),
            .y = try k.mul(self.y, rhs),
            .z = try k.mul(self.z, rhs),
        };
    }

    pub fn abs(self: Vec3, k: anytype) !Vec3 {
        return .{
            .x = try k.abs(self.x),
            .y = try k.abs(self.y),
            .z = try k.abs(self.z),
        };
    }

    pub fn min(self: Vec3, k: anytype, rhs: Vec3) !Vec3 {
        return .{
            .x = try k.min(self.x, rhs.x),
            .y = try k.min(self.y, rhs.y),
            .z = try k.min(self.z, rhs.z),
        };
    }

    pub fn max(self: Vec3, k: anytype, rhs: Vec3) !Vec3 {
        return .{
            .x = try k.max(self.x, rhs.x),
            .y = try k.max(self.y, rhs.y),
            .z = try k.max(self.z, rhs.z),
        };
    }

    pub fn dot(self: Vec3, k: anytype, rhs: Vec3) !builder.Value {
        const x_product = try k.mul(self.x, rhs.x);
        const y_product = try k.mul(self.y, rhs.y);
        const z_product = try k.mul(self.z, rhs.z);
        const xy = try k.add(x_product, y_product);
        return k.add(xy, z_product);
    }

    pub fn lengthSquared(self: Vec3, k: anytype) !builder.Value {
        return self.dot(k, self);
    }

    pub fn length(self: Vec3, k: anytype) !builder.Value {
        return k.sqrt(try self.lengthSquared(k));
    }

    pub fn distance(self: Vec3, k: anytype, rhs: Vec3) !builder.Value {
        return (try self.sub(k, rhs)).length(k);
    }
};
