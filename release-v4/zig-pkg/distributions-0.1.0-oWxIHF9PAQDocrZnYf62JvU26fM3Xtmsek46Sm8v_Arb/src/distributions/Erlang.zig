const std = @import("std");
const Random = std.Random;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;

pub fn Erlang(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        k: usize,
        lambda: Precision,
        dimensions: u64,
        interface: Distribution(Precision),

        pub fn sample(self: *Self, rng: Random) Precision {
            var product_u: Precision = 1.0;
            for (0..self.k) |_| {
                product_u *= rng.float(Precision);
            }
            // Protect against log(0)
            const safe_p = if (product_u == 0.0) std.math.floatEps(Precision) else product_u;
            return -@log(safe_p) / self.lambda;
        }

        pub fn sampleImpl(dist: *Distribution(Precision), rng: Random) Precision {
            const self: *Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(k: usize, lambda: Precision, dimensions: u64) @This() {
            return .{
                .k = k,
                .lambda = lambda,
                .dimensions = dimensions,
                .interface = Distribution(Precision){ 
                    .vtable = &.{ .sample = sampleImpl } 
                },
            };
        }
    };
}
