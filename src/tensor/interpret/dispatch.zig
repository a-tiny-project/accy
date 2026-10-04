pub fn primitive(comptime Value: type, impl: anytype, ctx: anytype) !?Value {
    const Impl = @TypeOf(impl.*);
    return switch (ctx.op.kind) {
        .parameter => if (comptime @hasDecl(Impl, "parameter")) try impl.parameter(ctx) else null,
        .constant => if (comptime @hasDecl(Impl, "constant")) try impl.constant(ctx) else null,
        .iota => if (comptime @hasDecl(Impl, "iota")) try impl.iota(ctx) else null,
        .broadcast => if (comptime @hasDecl(Impl, "broadcast")) try impl.broadcast(ctx) else null,
        .broadcast_in_dim => if (comptime @hasDecl(Impl, "broadcastInDim"))
            try impl.broadcastInDim(ctx)
        else
            null,
        .reshape => if (comptime @hasDecl(Impl, "reshape")) try impl.reshape(ctx) else null,
        .transpose => if (comptime @hasDecl(Impl, "transpose")) try impl.transpose(ctx) else null,
        .reduce => if (comptime @hasDecl(Impl, "reduce")) try impl.reduce(ctx) else null,
        .gather => if (comptime @hasDecl(Impl, "gather")) try impl.gather(ctx) else null,
        .scatter_add => if (comptime @hasDecl(Impl, "scatterAdd"))
            try impl.scatterAdd(ctx)
        else
            null,
        .sparse_cross_entropy => if (comptime @hasDecl(Impl, "sparseCrossEntropy"))
            try impl.sparseCrossEntropy(ctx)
        else
            null,
        .dot_general => if (comptime @hasDecl(Impl, "dotGeneral"))
            try impl.dotGeneral(ctx)
        else
            null,
        .compare => if (comptime @hasDecl(Impl, "compare")) try impl.compare(ctx) else null,
        .select => if (comptime @hasDecl(Impl, "select")) try impl.select(ctx) else null,
        .custom_call => if (comptime @hasDecl(Impl, "customCall"))
            try impl.customCall(ctx)
        else
            null,
        .scan => if (comptime @hasDecl(Impl, "scan")) try impl.scan(ctx) else null,
        .projection => if (comptime @hasDecl(Impl, "projection"))
            try impl.projection(ctx)
        else
            null,
        .unary => |unary| switch (unary.op) {
            .neg => if (comptime @hasDecl(Impl, "neg")) try impl.neg(ctx) else null,
            .abs => if (comptime @hasDecl(Impl, "abs")) try impl.abs(ctx) else null,
            .exp => if (comptime @hasDecl(Impl, "exp")) try impl.exp(ctx) else null,
            .log => if (comptime @hasDecl(Impl, "log")) try impl.log(ctx) else null,
            .sqrt => if (comptime @hasDecl(Impl, "sqrt")) try impl.sqrt(ctx) else null,
            .tanh => if (comptime @hasDecl(Impl, "tanh")) try impl.tanh(ctx) else null,
            .sin => if (comptime @hasDecl(Impl, "sin")) try impl.sin(ctx) else null,
            .cos => if (comptime @hasDecl(Impl, "cos")) try impl.cos(ctx) else null,
            .tan => if (comptime @hasDecl(Impl, "tan")) try impl.tan(ctx) else null,
        },
        .binary => |binary| switch (binary.op) {
            .add => if (comptime @hasDecl(Impl, "add")) try impl.add(ctx) else null,
            .sub => if (comptime @hasDecl(Impl, "sub")) try impl.sub(ctx) else null,
            .mul => if (comptime @hasDecl(Impl, "mul")) try impl.mul(ctx) else null,
            .div => if (comptime @hasDecl(Impl, "div")) try impl.div(ctx) else null,
            .max => if (comptime @hasDecl(Impl, "max")) try impl.max(ctx) else null,
            .min => if (comptime @hasDecl(Impl, "min")) try impl.min(ctx) else null,
            .pow => if (comptime @hasDecl(Impl, "pow")) try impl.pow(ctx) else null,
        },
    };
}
