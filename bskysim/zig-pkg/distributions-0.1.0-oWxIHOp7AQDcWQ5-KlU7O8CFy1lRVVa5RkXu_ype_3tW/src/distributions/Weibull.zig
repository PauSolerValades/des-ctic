const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const exp = std.math.exp;
const assert = std.debug.assert;

const pow = std.math.pow;

const Distribution = @import("../Distribution.zig").Distribution;
const Exponential = @import("Exponential.zig").Exponential;
const Uniform = @import("Uniform.zig").Uniform;
const Interval = @import("Uniform.zig").Interval;

/// Implements the Weibull distribution
/// $ f(x) = 1 - exp( -( x/lambda)^k )$
/// with the inverse transform method with the use of Uniform and Exponential
/// Inverse Weibull $ X = lambda · -ln( U ) ^(1/k) = lambda · E^(1/k) $
/// where U ~ Unif(0,1, cc) and E ~ exp(1)
pub fn Weibull(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        scale: Precision, // lambda
        shape: Precision, // k
        interface: PDist,

        pub fn init(scale: Precision, shape: Precision) @This() {
            assert(scale > 0);
            assert(shape > 0);
            return .{ .scale = scale, .shape = shape, .interface = PDist{ .vtable = &.{
                .sample = sampleImpl,
                .format = formatImpl,
            } } };
        }

        /// normal sampling
        pub fn sample(self: *const Self, rng: Random) Precision {
            const e = rng.floatExp(Precision);
            return self.scale * std.math.pow(Precision, e, 1.0 / self.shape);
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn cdf(self: *const Self, x: Precision) Precision {
            if (x <= 0) return 0;
            // F(x) = 1 − exp(−(x/λ)^k), x ≥ 0
            return 1 - exp(-pow(Precision, x / self.scale, self.shape));
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Weibull{{λ={d:.2}, k={d:.2}}}", .{ self.scale, self.shape });
        }
    };
}
