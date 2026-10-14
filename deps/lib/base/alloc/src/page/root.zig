const reserve = @import("reserve.zig");
const router = @import("router.zig");

pub const page_bytes = reserve.page_bytes;
pub const page_alignment = reserve.page_alignment;
pub const Reserve = reserve.Reserve;
pub const Router = router.Router;
