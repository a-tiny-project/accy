const contract = @import("contract.zig");

const Status = contract.Status;

/// Stable header that binds a frame to one loaded composition.
pub const Context = extern struct {
    version: u32,
    byte_size: u32,
    owner_address: u64,
    owner_cookie: u64,

    pub fn init(owner_address: u64, owner_cookie: u64) Context {
        return .{
            .version = contract.version,
            .byte_size = @sizeOf(Context),
            .owner_address = owner_address,
            .owner_cookie = owner_cookie,
        };
    }

    pub fn validate(self: *const Context) Status {
        if (self.version != contract.version or self.byte_size < @sizeOf(Context)) return .incompatible_context;
        if (self.owner_address == 0 or self.owner_cookie == 0) return .incompatible_context;
        return .ok;
    }
};
