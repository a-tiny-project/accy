const std = @import("std");
const choir = @import("../../root.zig");
const composition = @import("../root.zig");
const callsite = @import("callsite.zig");

const Allocator = std.mem.Allocator;
const product = choir.product;
const source = composition.source;

pub const CompositionVariantId = struct {
    value: u64,
};

pub const TargetChoiceSpec = struct {
    target: product.ProductRef,
    policy: product.ProductRef,

    pub fn eql(self: TargetChoiceSpec, other: TargetChoiceSpec) bool {
        return self.target.eql(other.target) and self.policy.eql(other.policy);
    }
};

pub const TargetChoice = struct {
    target: product.ProductRef,
    policy: product.ProductRef,

    pub fn init(allocator: Allocator, choice_spec: TargetChoiceSpec) Allocator.Error!TargetChoice {
        const target = try product.cloneProductRef(allocator, choice_spec.target);
        errdefer product.deinitProductRef(allocator, target);
        return .{
            .target = target,
            .policy = try product.cloneProductRef(allocator, choice_spec.policy),
        };
    }

    pub fn deinit(self: *TargetChoice, allocator: Allocator) void {
        product.deinitProductRef(allocator, self.policy);
        product.deinitProductRef(allocator, self.target);
        self.* = undefined;
    }

    pub fn eql(self: TargetChoice, choice_spec: TargetChoiceSpec) bool {
        return self.target.eql(choice_spec.target) and self.policy.eql(choice_spec.policy);
    }

    pub fn asSpec(self: TargetChoice) TargetChoiceSpec {
        return .{
            .target = self.target,
            .policy = self.policy,
        };
    }
};

pub const CompositionVariantSpec = struct {
    id: CompositionVariantId,
    choice: TargetChoiceSpec,
    fragments: []const source.FragmentId,
    call_sites: []const callsite.CallSiteSpec,
};

/// A complete physical-program choice for one target and policy identity.
/// Fragment choices cannot vary independently after this variant is selected.
pub const CompositionVariant = struct {
    id: CompositionVariantId,
    choice: TargetChoice,
    fragments: []const source.FragmentId,
    call_sites: []callsite.CallSite,

    pub fn init(allocator: Allocator, spec: CompositionVariantSpec) Allocator.Error!CompositionVariant {
        var choice = try TargetChoice.init(allocator, spec.choice);
        errdefer choice.deinit(allocator);
        const fragments = try allocator.dupe(source.FragmentId, spec.fragments);
        errdefer allocator.free(fragments);
        const calls = try allocator.alloc(callsite.CallSite, spec.call_sites.len);
        var calls_initialized: usize = 0;
        errdefer {
            var index = calls_initialized;
            while (index != 0) {
                index -= 1;
                calls[index].deinit(allocator);
            }
            allocator.free(calls);
        }
        for (spec.call_sites, calls) |call_spec, *call_value| {
            call_value.* = try callsite.CallSite.init(allocator, call_spec);
            calls_initialized += 1;
        }
        return .{
            .id = spec.id,
            .choice = choice,
            .fragments = fragments,
            .call_sites = calls,
        };
    }

    pub fn deinit(self: *CompositionVariant, allocator: Allocator) void {
        var call_index = self.call_sites.len;
        while (call_index != 0) {
            call_index -= 1;
            self.call_sites[call_index].deinit(allocator);
        }
        allocator.free(self.call_sites);
        allocator.free(self.fragments);
        self.choice.deinit(allocator);
        self.* = undefined;
    }

    pub fn containsFragment(self: *const CompositionVariant, id: source.FragmentId) bool {
        for (self.fragments) |fragment_id| {
            if (fragment_id.value == id.value) return true;
        }
        return false;
    }

    pub fn callSite(self: *const CompositionVariant, id: source.CallSiteId) ?*const callsite.CallSite {
        for (self.call_sites) |*call_site| {
            if (call_site.id.value == id.value) return call_site;
        }
        return null;
    }
};
