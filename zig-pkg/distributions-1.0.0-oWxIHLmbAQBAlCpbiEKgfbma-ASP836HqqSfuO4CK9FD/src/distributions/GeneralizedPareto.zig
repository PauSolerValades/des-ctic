const std = @import("std");
const Random = std.Random;
const Io = std.Io;
const assert = std.debug.assert;
const Distribution = @import("../Distribution.zig").Distribution;
const Uniform = @import("Uniform.zig").Uniform;

/// Implements the GeneralizedPareto distribution
pub fn GeneralizedPareto(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        location: Precision, // mu
        scale: Precision, // theta
        shape: Precision, // alpha
        unif: Uniform(Precision),
        interface: PDist,

        pub fn sample(self: *const Self, rng: Random) Precision {
            const u = self.unif.sample(rng); // [0,1)

            const eps = std.math.sqrt(std.math.floatEps(Precision));
            if (@abs(self.shape) < eps) return self.location - self.scale * @log(1.0 - u);
            const w = std.math.pow(Precision, 1.0 - u, -self.shape);
            return self.location + self.scale * (w - 1.0) / self.shape;
        }

        pub fn cdf(self: *const Self, x: Precision) Precision {
            const z = (x - self.location) / self.scale;
            if (z < 0) return 0;
            if (self.shape == 0) return 1 - std.math.exp(-z);
            const base = 1 + self.shape * z;
            if (base <= 0) return 1; // alpha < 0: x past the upper endpoint
            return 1 - std.math.pow(Precision, base, -1 / self.shape);
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(location: Precision, scale: Precision, shape: Precision) @This() {
            assert(scale > 0);
            return .{
                .location = location,
                .shape = shape,
                .scale = scale,
                .unif = Uniform(Precision).init(0, 1, .co),
                .interface = PDist{
                    .vtable = &.{ .sample = sampleImpl, .format = formatImpl },
                },
            };
        }

        pub fn initCenter(scale: Precision, shape: Precision) @This() {
            assert(scale > 0);
            return init(0, scale, shape);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("GeneralizedPareto{{μ={d:.2}, θ={d:.2}, α={d:.2}}}", .{ self.location, self.scale, self.shape });
        }
    };
}

test "cdf is inverse of quantile, support bounds" {
    const d = GeneralizedPareto(f64).init(2.0, 3.0, 0.5);
    // quantile(q) = mu + theta*((1-q)^(-alpha) - 1)/alpha
    const q = 2.0 + 3.0 * (std.math.pow(f64, 1.0 - 0.7, -0.5) - 1.0) / 0.5;
    try std.testing.expectApproxEqAbs(0.7, d.cdf(q), 1e-12);
    try std.testing.expectEqual(@as(f64, 0), d.cdf(1.0)); // below mu

    const d0 = GeneralizedPareto(f64).init(0.0, 1.0, 0.0);
    try std.testing.expectApproxEqAbs(1 - @exp(-2.0), d0.cdf(2.0), 1e-12);

    const dn = GeneralizedPareto(f64).init(0.0, 1.0, -0.5); // upper endpoint at 2
    try std.testing.expectEqual(@as(f64, 1), dn.cdf(3.0));
}
