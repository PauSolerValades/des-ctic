const std = @import("std");
const Random = std.Random;
const Io = std.Io;

const Constant = @import("distributions/Constant.zig").Constant;
const Exponential = @import("distributions/Exponential.zig").Exponential;
const Normal = @import("distributions/Normal.zig").Normal;
const Pareto = @import("distributions/Pareto.zig").Pareto;
const Uniform = @import("distributions/Uniform.zig").Uniform;

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
                // .exponential => |*exp| return exp.sample(rng),
                // .uniform => |*unif| return unif.sample(rng),
                // ...
                inline else => |*dist| try dist.format(writer),
            }
        }
    };
}
