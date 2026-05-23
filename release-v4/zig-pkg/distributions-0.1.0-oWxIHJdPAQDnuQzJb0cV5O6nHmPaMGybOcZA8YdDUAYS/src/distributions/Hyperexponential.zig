const std = @import("std");
const Random = std.Random;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;

pub fn HyperExponential(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        probs: []const Precision,
        rates: []const Precision,
        interface: Distribution(Precision),

        pub fn sample(self: *Self, rng: Random) Precision {
            const p = rng.float(Precision);
            var cumulative: Precision = 0.0;

            for (self.probs, 0..) |prob, i| {
                cumulative += prob;
                if (p <= cumulative) {
                    const u = rng.float(Precision);
                    return (1.0 / self.rates[i]) * (-@log(u));
                }
            }
            
            // Fallback
            const u = rng.float(Precision);
            return (1.0 / self.rates[self.rates.len - 1]) * (-@log(u));
        }

        pub fn sampleImpl(dist: *Distribution(Precision), rng: Random) Precision {
            const self: *Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(probs: []const Precision, rates: []const Precision) @This() {
            assert(probs.len == rates.len); // Safety check!
            return .{
                .probs = probs,
                .rates = rates,
                .interface = Distribution(Precision){ 
                    .vtable = &.{ .sample = sampleImpl } 
                },
            };
        }
    };
}
