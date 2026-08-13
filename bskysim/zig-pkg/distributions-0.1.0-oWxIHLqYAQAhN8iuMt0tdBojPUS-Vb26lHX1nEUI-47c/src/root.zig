//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const Distribution = @import("Distribution.zig").Distribution;

pub const Constant = @import("distributions/Constant.zig").Constant;
pub const Exponential = @import("distributions/Exponential.zig").Exponential;
pub const Normal = @import("distributions/Normal.zig").Normal;
pub const Pareto = @import("distributions/Pareto.zig").Pareto;
pub const GeneralizedPareto = @import("distributions/GeneralizedPareto.zig").GeneralizedPareto;
pub const Uniform = @import("distributions/Uniform.zig").Uniform;
pub const Interval = @import("distributions/Uniform.zig").Interval;
pub const Lognormal = @import("distributions/Lognormal.zig").Lognormal;
pub const Weibull = @import("distributions/Weibull.zig").Weibull;
pub const Gamma = @import("distributions/Gamma.zig").Gamma;
pub const Mixture = @import("distributions/Mixture.zig").Mixture;

pub const Categorical = @import("distributions/Categorical.zig").Categorical;
pub const ECDF = @import("distributions/ECDF.zig").ECDF;
pub const DiscreteUniform = @import("distributions/DiscreteUniform.zig").DiscreteUniform;

const unions = @import("UnionDist.zig");

pub const ContinuousDistribution = unions.ContinuousDistribution;
pub const DiscreteDistribution = unions.DiscreteDistribution;
pub const NonNegativeContinuousDistribution = unions.NonNegativeContinuousDistribution;
pub const PositiveContinuousDistribution = unions.PositiveContinuousDistribution;

const testing = std.testing;

test "test" {
    std.testing.refAllDecls(@This());
}

test "smoke: all distributions compile and sample" {
    const seed: u64 = 0xDEAD_BEEF;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

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
        try testing.expectApproxEqRel(0.10586188635928728, unif.sample(rng), 1e-14);
    }

    // Categorical f64 with i32 data
    {
        const w = [_]f64{ 0.2, 0.3, 0.5 };
        const d = [_]i32{ -1, 0, 1 };
        const cat = try Categorical(f64, i32).init(testing.allocator, &w, &d);
        defer cat.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 0), cat.sample(rng));
    }

    // Lognormal f64
    {
        const ln = Lognormal(f64).init(0.0, 1.0);
        try testing.expectApproxEqRel(2.5798756313626687, ln.sample(rng), 1e-14);
        // median is e^μ, so F(1) = 0.5 for LogNormal(0, 1)
        try testing.expectApproxEqRel(0.5, ln.cdf(1.0), 1e-6);
    }

    // Weibull f64
    {
        const wb = Weibull(f64).init(1.0, 2.0);
        try testing.expectApproxEqRel(0.6982549119369307, wb.sample(rng), 1e-14);
        // F(1) = 1 − e^(−1) for Weibull(λ=1, k=2)
        try testing.expectApproxEqRel(0.6321205588285577, wb.cdf(1.0), 1e-14);
    }

    // Gamma f64
    {
        const gm = Gamma(f64).init(2.0, 1.5);
        try testing.expect(gm.sample(rng) > 0);
        try testing.expect(gm.interface.sample(rng) > 0);
        // F(k*θ) ≈ 0.59 for Gamma(k=2, θ=1.5); exact: P(2, 2) = 1 − 3e^(−2)
        try testing.expectApproxEqRel(1 - 3 * @exp(-2.0), gm.cdf(3.0), 1e-12);
    }

    // GeneralizedPareto f64
    {
        const gpd: GeneralizedPareto(f64) = .init(1.0, 2.0, 0.5);
        try testing.expectApproxEqRel(1.722470832960247, gpd.sample(rng), 1e-14);
        try testing.expectApproxEqRel(5.966858970139439, gpd.interface.sample(rng), 1e-14);
        // F(3) = 1 − (1 + 0.5·(3−1)/2)^(−1/0.5) = 1 − 1.5⁻² for GPD(μ=1, θ=2, α=0.5)
        try testing.expectApproxEqRel(1 - 1.0 / 2.25, gpd.cdf(3.0), 1e-14);
    }

    // GeneralizedPareto f64, bounded (α < 0)
    {
        const gpd: GeneralizedPareto(f64) = .init(0, 1, -1); // bounded!
        try testing.expect(gpd.sample(rng) > 0);
        try testing.expectEqual(@as(f64, 1), gpd.cdf(2.0)); // past upper endpoint μ − θ/α = 1
    }

    {
        const p: Pareto(f64) = .init(1, 1);
        try testing.expect(p.sample(rng) > 0);
    }
}
