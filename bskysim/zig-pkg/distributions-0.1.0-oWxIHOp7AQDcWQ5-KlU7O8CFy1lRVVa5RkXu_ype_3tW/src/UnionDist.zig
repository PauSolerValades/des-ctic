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

// Distibutions that have an scritcly positive support.
pub fn NonNegativeContinuousDistribution(comptime Precision: type) type {
    return union(enum) {
        const Self = @This();

        constant: Constant(Precision),
        lognorm: Lognormal(Precision),
        weibull: Weibull(Precision),
        gamma: Gamma(Precision),
        pareto: Pareto(Precision),
        gpareto: GeneralizedPareto(Precision),
        exponential: Exponential(Precision),

        pub fn sample(self: *const Self, rng: Random) Precision {
            switch (self.*) {
                .gpareto => {
                    // for every value of alpha, mu must just be bigger than 0 and the
                    // support will be negative. alpha < 0, will be also bounded
                    std.debug.assert(self.location >= 0);
                    return self.gpareto.sample(rng);
                },
                .constant => {
                    std.debug.assert(self.value >= 0);
                    return self.constant.sample(rng);
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
