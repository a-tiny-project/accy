pub fn main() void {
    var total: u32 = 0;
    for (0..16) |index| total += @intCast(index);
    if (total != 120) unreachable;
}
