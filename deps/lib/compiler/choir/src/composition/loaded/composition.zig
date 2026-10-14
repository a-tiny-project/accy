const std = @import("std");
const composition = @import("../root.zig");
const loaded = @import("root.zig");

const Allocator = std.mem.Allocator;
const abi = composition.abi;
const model = composition.module;
const source = composition.source;

pub const ValidationError = model.VerificationError || error{
    DuplicateFragmentMaterializer,
    DuplicateLoadedState,
    MissingFragmentMaterializer,
    MissingTargetVariant,
};

pub const EntryError = error{
    AbiMismatch,
    MissingEntry,
    MissingFragment,
    FragmentOutsideVariant,
    UndeclaredExport,
};

/// Owns one verified target variant and all process-local fragment state.
/// Every `Invocation` created from this owner must be deinitialized first;
/// violating that `deinit` precondition panics. Destruction releases fragments
/// before durable module storage.
pub const LoadedComposition = struct {
    allocator: Allocator,
    module: model.CompositionModule,
    selected_variant: model.CompositionVariantId,
    fragments: []loaded.LoadedFragment,
    context: abi.Context,
    invocations: loaded.gate.Gate = .{},
    lifecycle: loaded.lifecycle.Recorder,

    pub const initOwned = initOwnedImpl;
    pub const deinit = deinitImpl;
    pub const contextPointer = contextPointerImpl;
    pub const loadedFragment = loadedFragmentImpl;
    /// Resolves a declared export to its nonzero process-local raw address.
    /// The address is valid only while this composition remains loaded.
    pub const entryAddress = entryAddressImpl;
    pub const reserveInvocation = reserveInvocationImpl;
    pub const releaseInvocation = releaseInvocationImpl;
    pub const activeInvocationCount = activeInvocationCountImpl;
};

fn initOwnedImpl(
    allocator: Allocator,
    module: model.CompositionModule,
    choice: model.TargetChoiceSpec,
    materializers: []const loaded.FragmentMaterializer,
    observer: ?loaded.LifecycleObserver,
) anyerror!*LoadedComposition {
    var owned_module = module;
    var module_transferred = false;
    errdefer if (!module_transferred) owned_module.deinit();
    try owned_module.verify();
    const selected_variant = owned_module.selectVariant(choice) orelse return error.MissingTargetVariant;
    try validateMaterializers(&owned_module, selected_variant, materializers);

    const owned_fragments = try allocator.alloc(loaded.LoadedFragment, materializers.len);
    var fragments_transferred = false;
    errdefer if (!fragments_transferred) allocator.free(owned_fragments);
    const owner = try allocator.create(LoadedComposition);
    var owner_initialized = false;
    errdefer if (!owner_initialized) allocator.destroy(owner);
    const cookie = nonzeroCookie(@intFromPtr(owner));
    owner.* = .{
        .allocator = allocator,
        .module = owned_module,
        .selected_variant = selected_variant.id,
        .fragments = owned_fragments,
        .context = abi.Context.init(@intFromPtr(owner), cookie),
        .lifecycle = loaded.lifecycle.Recorder.init(observer),
    };
    module_transferred = true;
    fragments_transferred = true;
    owner_initialized = true;

    var materialized_count: usize = 0;
    errdefer {
        loaded.fragment.deinitUnique(allocator, owned_fragments[0..materialized_count], owner.lifecycle.serialized());
        allocator.free(owned_fragments);
        owner.module.deinit();
        allocator.destroy(owner);
    }
    const durable_variant = owner.module.variant(owner.selected_variant).?;
    for (materializers) |materializer| {
        std.debug.assert(durable_variant.containsFragment(materializer.id));
        const durable_fragment = owner.module.fragment(materializer.id).?;
        const result = try materializer.materialize(materializer.context, allocator, &owner.module, durable_fragment);
        owned_fragments[materialized_count] = .{
            .id = materializer.id,
            .state = result.state,
            .vtable = result.vtable,
        };
        materialized_count += 1;
        if (hasAliasedState(owned_fragments[0..materialized_count])) return error.DuplicateLoadedState;
    }

    return owner;
}

fn deinitImpl(self: *LoadedComposition) void {
    self.invocations.close();
    const allocator = self.allocator;
    loaded.fragment.deinitUnique(allocator, self.fragments, self.lifecycle.serialized());
    allocator.free(self.fragments);
    self.module.deinit();
    self.lifecycle.record(.composition_destroyed);
    self.* = undefined;
    allocator.destroy(self);
}

fn contextPointerImpl(self: *LoadedComposition) *abi.Context {
    return &self.context;
}

fn loadedFragmentImpl(self: *const LoadedComposition, id: source.FragmentId) ?loaded.LoadedFragment {
    for (self.fragments) |fragment_value| {
        if (fragment_value.id.value == id.value) return fragment_value;
    }
    return null;
}

fn entryAddressImpl(self: *const LoadedComposition, id: source.FragmentId, export_name: []const u8) EntryError!usize {
    const selected_variant = self.module.variant(self.selected_variant) orelse return error.MissingFragment;
    if (!selected_variant.containsFragment(id)) return error.FragmentOutsideVariant;
    const durable_fragment = self.module.fragment(id) orelse return error.MissingFragment;
    const declared_export = durable_fragment.exportByName(export_name) orelse return error.UndeclaredExport;
    if (declared_export.abi_version != abi.version) return error.AbiMismatch;
    const runtime_fragment = self.loadedFragment(id) orelse return error.MissingFragment;
    const lookup = runtime_fragment.vtable.lookup_export orelse return error.MissingEntry;
    const address = lookup(runtime_fragment.state, declared_export.symbol) orelse return error.MissingEntry;
    if (address == 0) return error.MissingEntry;
    return address;
}

fn reserveInvocationImpl(self: *LoadedComposition) ?u64 {
    return self.invocations.reserve();
}

fn releaseInvocationImpl(self: *LoadedComposition, id: u64) void {
    self.lifecycle.record(.{ .invocation_destroyed = id });
    self.invocations.release();
}

fn activeInvocationCountImpl(self: *const LoadedComposition) u64 {
    return self.invocations.activeCount();
}

fn validateMaterializers(
    module: *const model.CompositionModule,
    variant: *const model.CompositionVariant,
    materializers: []const loaded.FragmentMaterializer,
) ValidationError!void {
    if (materializers.len != variant.fragments.len) return error.MissingFragmentMaterializer;
    for (materializers, 0..) |materializer, index| {
        if (!variant.containsFragment(materializer.id) or module.fragment(materializer.id) == null) return error.MissingFragmentMaterializer;
        for (materializers[0..index]) |previous| {
            if (previous.id.value == materializer.id.value) return error.DuplicateFragmentMaterializer;
        }
    }
}

fn hasAliasedState(fragments: []const loaded.LoadedFragment) bool {
    if (fragments.len < 2) return false;
    const newest = fragments[fragments.len - 1];
    for (fragments[0 .. fragments.len - 1]) |previous| {
        if (previous.state == newest.state) return true;
    }
    return false;
}

fn nonzeroCookie(address: usize) u64 {
    const value: u64 = @intCast(address);
    const mixed = value ^ 0x9e3779b97f4a7c15;
    return if (mixed == 0) 1 else mixed;
}
