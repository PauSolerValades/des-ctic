const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;
const table = @import("../tables.zig");
const Normal = @import("Normal.zig").Normal;

/// Implements the lognormal distribution
pub fn Lognormal(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        mean: Precision, // mu
        variance: Precision, // sigma
        interface: PDist,
        norm: Normal(Precision),

        /// Uses Ziggurat with this trick P = x_m * e^(E/alpha) where E ~ exp(1)
        pub fn sample(self: *const Self, rng: Random) Precision {
            return std.math.exp(self.norm.sample(rng));
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(mean: Precision, variance: Precision) @This() {
            assert(variance >= 0);
            return .{
                .mean = mean,
                .variance = variance,
                .norm = Normal(Precision).init(mean, variance),
                .interface = PDist{
                    .vtable = &.{ .sample = sampleImpl, .format = formatImpl },
                },
            };
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Lognormal{{μ={d:.2}, σ²={d:.2}}}", .{ self.mean, self.variance });
        }
        pub fn cdf(self: *const Self, x: Precision) Precision {
            if (x <= 0) return 0;
            // X ~ LogNormal(μ, σ²) ⟺ ln X ~ Normal(μ, σ²), so F(x) = Φ((ln x − μ)/σ)
            return self.norm.cdf(@log(x));
        }
    };
}
