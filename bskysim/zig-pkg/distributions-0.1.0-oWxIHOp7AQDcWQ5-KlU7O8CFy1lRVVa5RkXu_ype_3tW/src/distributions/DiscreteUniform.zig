const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;
const Io = std.Io;

const Distribution = @import("../Distribution.zig").Distribution;

pub const Interval = enum {
    oo, // (a,b)
    oc, // (a,b]
    co, // [a,b)
    cc, // [a,b]
};

/// Implementation of the Uniform Distribution:
/// $ f(x) = frac(1, b-a) $
/// $ F(x) =
pub fn DiscreteUniform(comptime DataType: type) type {
    if (@typeInfo(DataType) != .int) @compileError("Type must be either an unsigned or signed int.");

    return struct {
        const Self = @This(); // = Uniform(Precision)
        const PDist: type = Distribution(DataType);

        min: DataType,
        max: DataType,
        interval: Interval,
        interface: PDist,

        pub fn init(min: DataType, max: DataType, interval: Interval) Self {
            assert(max >= min);
            return .{ .min = min, .max = max, .interval = interval, .interface = .{ .vtable = &.{ .sample = sampleImpl, .format = formatImpl } } };
        }

        // uses the rng instance to get a float between 0 and 1 and then scales i
        pub inline fn sample(self: *const Self, rng: Random) DataType {
            switch (self.interval) {
                // standard case
                .co => return rng.intRangeAtMost(DataType, self.min, self.max - 1),
                .oc => return rng.intRangeAtMost(DataType, self.min + 1, self.max),
                .oo => return rng.intRangeAtMost(DataType, self.min + 1, self.max - 1),
                .cc => return rng.intRangeAtMost(DataType, self.min, self.max),
            }
        }

        /// Function to put into the VTable of Distribution
        fn sampleImpl(dist: *const PDist, rng: Random) DataType {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        /// Discrete cdf: F(x) = P(X <= x) over the integers in the interval.
        pub fn cdf(self: *const Self, x: f64) f64 {
            const lo: f64 = switch (self.interval) {
                .oo, .oc => @floatFromInt(self.min + 1),
                .co, .cc => @floatFromInt(self.min),
            };
            const hi: f64 = switch (self.interval) {
                .oo, .co => @floatFromInt(self.max - 1),
                .oc, .cc => @floatFromInt(self.max),
            };
            if (x < lo) return 0.0;
            if (x >= hi) return 1.0;
            return (@floor(x) - lo + 1.0) / (hi - lo + 1.0);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Unif{{{d:.2}, {d:.2}}}", .{ self.min, self.max });
        }
    };
}
