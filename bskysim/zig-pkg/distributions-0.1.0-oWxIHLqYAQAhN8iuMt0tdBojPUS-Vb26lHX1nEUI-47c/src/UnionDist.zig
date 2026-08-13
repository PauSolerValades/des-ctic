const std = @import("std");
const Random = std.Random;
const Io = std.Io;

const Constant = @import("distributions/Constant.zig").Constant;
const Exponential = @import("distributions/Exponential.zig").Exponential;
const Normal = @import("distributions/Normal.zig").Normal;
const Pareto = @import("distributions/Pareto.zig").Pareto;
const Uniform = @import("distributions/Uniform.zig").Uniform;
const Lognormal = @import("distributions/Lognormal.zig").Lognormal;
const Weibull = @import("distributions/Weibull.zig").Weibull;
const Gamma = @import("distributions/Gamma.zig").Gamma;
const GeneralizedPareto = @import("distributions/GeneralizedPareto.zig").GeneralizedPareto;

const DiscreteUniform = @import("distributions/DiscreteUniform.zig").DiscreteUniform;
const Categorical = @import("distributions/Categorical.zig").Categorical;
const ECDF = @import("distributions/ECDF.zig").ECDF;

pub fn ContinuousDistribution(comptime Precision: type) type {
    if (@typeInfo(Precision) != .float) @compileError("Precision must be a floating point number\n");

    return union(enum) {
        const Self = @This();

        constant: Constant(Precision),
        exponential: Exponential(Precision),
        normal: Normal(Precision),
        pareto: Pareto(Precision),
        uniform: Uniform(Precision),
        ecdf: ECDF(Precision, Precision),
        lognorm: Lognormal(Precision),
        weibull: Weibull(Precision),
        gamma: Gamma(Precision),
        gpareto: GeneralizedPareto(Precision),

        pub fn sample(self: *const Self, rng: Random) Precision {
            switch (self.*) {
                // generates this:
                // .constant => |*c| return c.sample(rng),
                // .exponential => |*exp| return exp.sample(rng),
                // .uniform => |*unif| return unif.sample(rng),
                // ...
                inline else => |*dist| return dist.sample(rng),
            }
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            switch (self.*) {
                // generates this:
                // .constant => |*c| return c.sample(rng),
                // .exponential => |*exp| return exp.sample(rng),
                // .uniform => |*unif| return unif.sample(rng),
                // ...
                inline else => |*dist| try dist.format(writer),
            }
        }
    };
}

pub fn DiscreteDistribution(comptime Precision: type, comptime DataType: type) type {
    if (@typeInfo(Precision) != .float) @compileError("Precision must be a floating point number\n");

    return union(enum) {
        const Self = @This();

        constant: Constant(DataType),
        categorical: Categorical(Precision, DataType),
        uniform: DiscreteUniform(DataType),
        ecdf: ECDF(Precision, DataType),

        pub fn sample(self: *const Self, rng: Random) DataType {
            switch (self.*) {
                inline else => |*dist| return dist.sample(rng),
            }
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            switch (self.*) {
                // generates this:
                // .constant => |*c| return c.sample(rng),
                // .categorical => |*exp| return cat.sample(rng),
                // .uniform => |*unif| return unif.sample(rng),
                // ...
                inline else => |*dist| try dist.format(writer),
            }
        }
    };
}

const assert = std.debug.assert;
// Distibutions that have an scritcly positive support.
pub fn NonNegativeContinuousDistribution(comptime Precision: type) type {
    return union(enum) {
        const Self = @This();

        constant: Constant(Precision),
        uniform: Uniform(Precision),
        lognormal: Lognormal(Precision),
        weibull: Weibull(Precision),
        gamma: Gamma(Precision),
        pareto: Pareto(Precision),
        gpareto: GeneralizedPareto(Precision),
        exponential: Exponential(Precision),

        pub fn sample(self: *const Self, rng: Random) Precision {
            switch (self.*) {
                .gpareto => |*g| {
                    // for every value of alpha, mu must just be bigger than 0 and the
                    // support will be negative. alpha < 0, will be also bounded
                    assert(g.location >= 0);
                    return g.sample(rng);
                },
                .constant => |*c| {
                    assert(c.value >= 0);
                    return c.sample(rng);
                },
                .uniform => |*u| {
                    assert(u.min >= 0);
                    return u.sample(rng);
                },
                inline else => |*dist| return dist.sample(rng),
            }
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            switch (self.*) {
                // generates this:
                // .constant => |*c| return c.sample(rng),
                // .categorical => |*exp| return cat.sample(rng),
                // .uniform => |*unif| return unif.sample(rng),
                // ...
                inline else => |*dist| try dist.format(writer),
            }
        }
    };
}

/// all distributions in which support does not include 0 and are positive.
/// Is a subset of NonNegative
pub fn PositiveContinuousDistribution(comptime Precision: type) type {
    return union(enum) {
        const Self = @This();

        lognormal: Lognormal(Precision),
        gamma: Gamma(Precision),
        pareto: Pareto(Precision),
        constant: Constant(Precision),
        uniform: Uniform(Precision),
        gpareto: GeneralizedPareto(Precision),

        pub fn sample(self: *const Self, rng: Random) Precision {
            switch (self.*) {
                .gpareto => |*g| {
                    // for every value of alpha, mu must just be bigger than 0 and the
                    // support will be negative. alpha < 0, will be also bounded
                    assert(g.location > 0);
                    return g.sample(rng);
                },
                .constant => |*c| {
                    assert(c.value > 0);
                    return c.sample(rng);
                },
                .uniform => |*u| {
                    assert(u.min >= 0);
                    return u.sample(rng);
                },
                inline else => |*dist| return dist.sample(rng),
            }
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            switch (self.*) {
                // generates this:
                // .constant => |*c| return c.sample(rng),
                // .categorical => |*exp| return cat.sample(rng),
                // .uniform => |*unif| return unif.sample(rng),
                // ...
                inline else => |*dist| try dist.format(writer),
            }
        }
    };
}

const expect = std.testing.expect;

test "ContinuousDistribution" {
    const U = ContinuousDistribution(f64);
    const ta = std.testing.allocator;

    var ecdf_data = [_]f64{ 1, 2, 3 };
    const ecdf = try ECDF(f64, f64).init(ta, &ecdf_data);
    defer ecdf.deinit(ta);

    const cases = [_]U{
        .{ .constant = Constant(f64).init(1) },
        .{ .exponential = Exponential(f64).init(2) },
        .{ .normal = Normal(f64).init(5, 2) },
        .{ .pareto = Pareto(f64).init(1, 1.5) },
        .{ .uniform = Uniform(f64).init(3, 4, .cc) },
        .{ .ecdf = ecdf },
        .{ .lognorm = Lognormal(f64).init(0, 1) },
        .{ .weibull = Weibull(f64).init(2, 3) },
        .{ .gamma = Gamma(f64).init(2, 2) },
        .{ .gpareto = GeneralizedPareto(f64).init(1, 1, 0.5) },
    };
    // check for when more variants are added
    try expect(cases.len == std.meta.fields(U).len);

    for (&cases) |*d| {
        switch (d.*) {
            .constant => |c| try expect(c.value == 1),
            .exponential => |e| try expect(e.rate == 2),
            .normal => |n| try expect(n.mean == 5 and n.variance == 2),
            .pareto => |p| try expect(p.scale == 1 and p.shape == 1.5),
            .uniform => |u| try expect(u.min == 3 and u.max == 4),
            .ecdf => |e| try expect(e.bins.len == 3),
            .lognorm => |l| try expect(l.mean == 0 and l.variance == 1),
            .weibull => |w| try expect(w.scale == 2 and w.shape == 3),
            .gamma => |g| try expect(g.shape == 2 and g.scale == 2),
            .gpareto => |g| try expect(g.location == 1 and g.scale == 1 and g.shape == 0.5),
        }
    }
}

test "DiscreteDistribution" {
    const U = DiscreteDistribution(f64, u32);
    const ta = std.testing.allocator;

    const weights = [_]f64{ 0.5, 0.5 };
    const cat_data = [_]u32{ 10, 20 };
    const cat = try Categorical(f64, u32).init(ta, &weights, &cat_data);
    defer cat.deinit(ta);

    var ecdf_data = [_]u32{ 1, 2, 3 };
    const ecdf = try ECDF(f64, u32).init(ta, &ecdf_data);
    defer ecdf.deinit(ta);

    const cases = [_]U{
        .{ .constant = Constant(u32).init(7) },
        .{ .categorical = cat },
        .{ .uniform = DiscreteUniform(u32).init(1, 6, .cc) },
        .{ .ecdf = ecdf },
    };
    // check for when more variants are added
    try expect(cases.len == std.meta.fields(U).len);

    for (&cases) |*d| {
        switch (d.*) {
            .constant => |c| try expect(c.value == 7),
            .categorical => |c| try expect(c.data.len == 2 and c.weights[0] == 0.5),
            .uniform => |u| try expect(u.min == 1 and u.max == 6),
            .ecdf => |e| try expect(e.bins.len == 3),
        }
    }
}

test "NonNegativeContinuousDistribution" {
    const U = NonNegativeContinuousDistribution(f64);
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const cases = [_]U{
        .{ .constant = Constant(f64).init(0) },
        .{ .uniform = Uniform(f64).init(0, 2, .cc) },
        .{ .lognormal = Lognormal(f64).init(0, 1) },
        .{ .weibull = Weibull(f64).init(2, 3) },
        .{ .gamma = Gamma(f64).init(2, 2) },
        .{ .pareto = Pareto(f64).init(1, 1.5) },
        .{ .gpareto = GeneralizedPareto(f64).init(0, 1, 0.5) },
        .{ .exponential = Exponential(f64).init(2) },
    };
    // check for when more variants are added
    try expect(cases.len == std.meta.fields(U).len);

    for (&cases) |*d| {
        switch (d.*) {
            .constant => |c| try expect(c.value == 0),
            .uniform => |u| try expect(u.min == 0 and u.max == 2),
            .lognormal => |l| try expect(l.mean == 0 and l.variance == 1),
            .weibull => |w| try expect(w.scale == 2 and w.shape == 3),
            .gamma => |g| try expect(g.shape == 2 and g.scale == 2),
            .pareto => |p| try expect(p.scale == 1 and p.shape == 1.5),
            .gpareto => |g| try expect(g.location == 0 and g.scale == 1 and g.shape == 0.5),
            .exponential => |e| try expect(e.rate == 2),
        }
        // a 100-sample loop can't prove a bound
        // welp.
        for (0..100) |_| try expect(d.sample(rng) >= 0);
    }
}

test "PositiveContinuousDistribution" {
    const U = PositiveContinuousDistribution(f64);
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const cases = [_]U{
        .{ .lognormal = Lognormal(f64).init(0, 1) },
        .{ .gamma = Gamma(f64).init(2, 2) },
        .{ .pareto = Pareto(f64).init(1, 1.5) },
        .{ .constant = Constant(f64).init(3) },
        .{ .uniform = Uniform(f64).init(0, 2, .oo) }, // min=0 legal: .oo never yields exactly min
        .{ .gpareto = GeneralizedPareto(f64).init(1, 1, 0.5) },
    };
    // check for when more variants are added
    try expect(cases.len == std.meta.fields(U).len);

    for (&cases) |*d| {
        switch (d.*) {
            .lognormal => |l| try expect(l.mean == 0 and l.variance == 1),
            .gamma => |g| try expect(g.shape == 2 and g.scale == 2),
            .pareto => |p| try expect(p.scale == 1 and p.shape == 1.5),
            .constant => |c| try expect(c.value == 3),
            .uniform => |u| try expect(u.min == 0 and u.max == 2),
            .gpareto => |g| try expect(g.location == 1 and g.scale == 1 and g.shape == 0.5),
        }
        // same caveat as NonNegative: 100 samples prove nothing, welp.
        for (0..100) |_| try expect(d.sample(rng) > 0);
    }
}
