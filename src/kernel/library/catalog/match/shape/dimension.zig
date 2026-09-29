pub fn positiveDim(dim: i64) ?u64 {
    if (dim <= 0) return null;
    return @intCast(dim);
}
