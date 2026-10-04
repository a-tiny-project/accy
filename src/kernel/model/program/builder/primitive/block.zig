const common = @import("common.zig");

const builder = common.builder;

pub fn argument(owner: anytype, index: usize) builder.Value {
    return owner.body.argument(index);
}

pub fn entryBlock(owner: anytype) builder.Block {
    return owner.body.entryBlock();
}

pub fn insertionBlock(owner: anytype) builder.Block {
    return owner.body.insertionBlock();
}

pub fn setInsertionBlock(owner: anytype, block: builder.Block) void {
    owner.body.setInsertionBlock(block);
}

pub fn enterBlock(owner: anytype, block: builder.Block) !builder.InsertionScope {
    return owner.body.enterBlock(block);
}
