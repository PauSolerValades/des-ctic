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
pub fn Uniform(comptime Precision: type) type {
    
    return struct {
        const Self = @This(); // = Uniform(Precision)
        const PDist: type = Distribution(Precision);

        min: Precision,
        max: Precision,
        interval: Interval,
        interface: PDist,
 
        pub fn init(min: Precision, max: Precision, interval: Interval) Self {
            assert(max > min);
            return .{
                .min = min,
                .max = max,
                .interval = interval,
                .interface = .{ .vtable = &.{ .sample = sampleImpl, .format = formatImpl } }
            };
        }   

        // uses the rng instance to get a float between 0 and 1 and then scales it
        pub inline fn sample(self: *const Self, rng: Random) Precision {
            const scale = self.min + (self.max - self.min);
            switch (self.interval) {
                // standard case
                .co => return scale * rng.float(Precision),
                .oc => return scale * (1 - rng.float(Precision)),
                .oo => {
                    var u = rng.float(Precision);
                    // this will happen not very often (1/9mill in f64?), a while does not seem that bad?
                    while (u == 0.0) {
                        u = rng.float(Precision);
                    }
                    return scale * u;
                },
                .cc => {
                    const inf = std.math.inf(Precision);
                    const b_adj = std.math.nextAfter(Precision, self.max, inf);
                    
                    const result = self.min + (b_adj - self.min) * rng.float(Precision);
                    
                    return @min(self.max, result);
                },
            }
        }

        /// Function to put into the VTable of Distribution
        fn sampleImpl(dist: *const PDist, rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn unifCdf(min: Precision, max: Precision, interval: Interval, x: Precision) Precision {
            const CompareOperator = std.math.CompareOperator;
            const lower: CompareOperator = switch (interval) {
                .oo, .oc => .lt,
                .co, .cc => .lte,    
            };
            const upper: CompareOperator = switch (interval) {
                .oc, .cc => .gt,
                .co, .oo => .gte,
            };

            if (std.math.order(x, min).compare(lower)) {
                return 0.0;
            } else if (std.math.order(x, max).compare(upper)) {
                return 1.0;
            } else {
                return (x - min) / (max - min);
            }
        }
       
        pub fn cdf(self: *const Self, x: Precision) Precision {
            return unifCdf(self.min, self.max, self.Interval, x);             
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const Params = struct { min: Precision, max: Precision, interval: Interval };

            const parsed = try std.json.innerParse(Params, allocator, source, options);

            return init(parsed.min, parsed.max, parsed.interval);
        }
        
        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Unif{{{d:.2}, {d:.2}}}", .{self.min, self.max});
        }
    };
}

