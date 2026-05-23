//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const Distribution = @import("Distribution.zig").Distribution;

pub const Constant = @import("distributions/Constant.zig").Constant;
pub const Exponential = @import("distributions/Exponential.zig").Exponential;
pub const Normal = @import("distributions/Normal.zig").Normal;
pub const Pareto = @import("distributions/Pareto.zig");
pub const Uniform = @import("distributions/Uniform.zig").Uniform;
pub const Interval = @import("distributions/Uniform.zig").Interval;

pub const Categorical = @import("distributions/Categorical.zig").Categorical;
pub const ECDF = @import("distributions/ECDF.zig").ECDF;

const unions = @import("UnionDist.zig");

pub const ContinuousDistribution = unions.ContinuousDistribution;
pub const DiscreteDistribution = unions.DiscreteDistribution;

const testing = std.testing;

test "smoke: all distributions compile and sample" {
    const seed: u64 = 0xDEAD_BEEF;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // ── f32 ──────────────────────────────────────────────

    // Exponential
    {
        const exp = Exponential(f32).init(2.0);
        try testing.expectApproxEqRel(1.3478217, exp.sample(rng), 1e-6);
        try testing.expectApproxEqRel(0.44263467, exp.interface.sample(rng), 1e-6);

        var cu = ContinuousDistribution(f32){ .exponential = exp };
        try testing.expectApproxEqRel(0.09220093, cu.sample(rng), 1e-6);
    }

    // Normal
    {
        const norm = Normal(f32).init(0.0, 1.0);
        try testing.expectApproxEqRel(-0.5145237, norm.sample(rng), 1e-6);
        try testing.expectApproxEqRel(0.16476992, norm.interface.sample(rng), 1e-6);
    }

    // Uniform — all four intervals
    {
        inline for (.{ Interval.oo, Interval.oc, Interval.co, Interval.cc }) |intvl| {
            const unif = Uniform(f32).init(0.0, 1.0, intvl);
            _ = unif.sample(rng);

            var cu = ContinuousDistribution(f32){ .uniform = unif };
            _ = cu.sample(rng);
        }
    }

    // Constant (as continuous)
    {
        const c = Constant(f32).init(7.0);
        try testing.expectEqual(7.0, c.sample(rng));

        var cu = ContinuousDistribution(f32){ .constant = c };
        try testing.expectEqual(7.0, cu.sample(rng));
    }

    // Constant (as discrete, in DiscreteDistribution union)
    {
        const cd = Constant(u8).init(42);
        var du = DiscreteDistribution(f32, u8){ .constant = cd };
        try testing.expectEqual(@as(u8, 42), du.sample(rng));
    }

    // Categorical — f32 weights, u8 data
    {
        const weights = [_]f32{ 0.3, 0.7 };
        const data = [_]u8{ 10, 20 };
        const cat = try Categorical(f32, u8).init(testing.allocator, &weights, &data);
        defer cat.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 20), cat.sample(rng));

        var du = DiscreteDistribution(f32, u8){ .categorical = cat };
        try testing.expectEqual(@as(u8, 20), du.sample(rng));
    }

    // Categorical — f64 weights, f32 data
    {
        const w = [_]f64{ 0.5, 0.5 };
        const d = [_]f32{ 1.0, 2.0 };
        const cat = try Categorical(f64, f32).init(testing.allocator, &w, &d);
        defer cat.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 1.0), cat.sample(rng));
    }

    // ECDF — f32 precision, u32 data
    {
        var data = [_]u32{ 1, 1, 2, 2, 3, 3 };
        const ecdf = try ECDF(f32, u32).init(testing.allocator, &data);
        defer ecdf.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 3), ecdf.sample(rng));

        var du = DiscreteDistribution(f32, u32){ .ecdf = ecdf };
        try testing.expectEqual(@as(u32, 3), du.sample(rng));
    }

    // ECDF — f64 precision, f64 data
    {
        var data = [_]f64{ 1.0, 2.0, 3.0 };
        const ecdf = try ECDF(f64, f64).init(testing.allocator, &data);
        defer ecdf.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 1.0), ecdf.sample(rng));
    }

    // ── f64 ──────────────────────────────────────────────

    // Exponential f64
    {
        const exp = Exponential(f64).init(1.5);
        try testing.expectApproxEqRel(0.3397904266498015, exp.sample(rng), 1e-14);
    }

    // Normal f64
    {
        const norm = Normal(f64).init(2.0, 4.0);
        try testing.expectApproxEqRel(5.449796702821329, norm.sample(rng), 1e-14);
    }

    // Uniform f64
    {
        const unif = Uniform(f64).init(-1.0, 1.0, .co);
        try testing.expectApproxEqRel(0.5529309431796436, unif.sample(rng), 1e-14);
    }

    // Categorical f64 with i32 data
    {
        const w = [_]f64{ 0.2, 0.3, 0.5 };
        const d = [_]i32{ -1, 0, 1 };
        const cat = try Categorical(f64, i32).init(testing.allocator, &w, &d);
        defer cat.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 0), cat.sample(rng));
    }
}
