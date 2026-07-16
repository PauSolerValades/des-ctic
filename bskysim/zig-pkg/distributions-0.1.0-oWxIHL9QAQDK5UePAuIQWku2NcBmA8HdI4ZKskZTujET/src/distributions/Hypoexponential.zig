const std = @import("std");
const Random = std.Random;

const Distribution = @import("../Distribution.zig").Distribution;

pub fn HypoExponential(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        rates: []const Precision,
        dimensions: u64,
        interface: Distribution(Precision),

        pub fn sample(self: *Self, rng: Random) Precision {
            var sum: Precision = 0.0;
            for (self.rates) |lambda| {
                const u = rng.float(Precision);
                sum += (1.0 / lambda) * (-@log(u));
            }
            return sum;
        }

        pub fn sampleImpl(dist: *Distribution(Precision), rng: Random) Precision {
            const self: *Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(rates: []const Precision, dimensions: u64) @This() {
            return .{
                .rates = rates,
                .dimensions = dimensions,
                .interface = Distribution(Precision){ 
                    .vtable = &.{ .sample = sampleImpl } 
                },
            };
        }
    };
}
