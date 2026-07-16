const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;
const table = @import("../tables.zig");
const Exponential = @import("Exponential.zig").Exponential;

/// Implements the Pareto distribution
/// F(x) = 1 - (scale / x)^shape
/// It samples using the highly optimized Exponential Ziggurat transform.
pub fn Pareto(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        shape: Precision, // alpha
        scale: Precision, // x_m
        interface: PDist,
        exp: Exponential(Precision),

        /// Uses Ziggurat with this trick P = x_m * e^(E/alpha) where E ~ exp(1)
        pub fn sample(self: *const Self, rng: Random) Precision {
            return self.scale * std.math.exp(self.exp.sample(rng) / self.shape);
        }

        /// Pareto CDF: F(x) = 1 - (scale / x)^shape  for x >= scale, else 0
        pub fn cdf(self: *const Self, x: Precision) Precision {
            if (x < self.scale) return 0.0;
            return 1.0 - std.math.pow(Precision, self.scale / x, self.shape);
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(shape: Precision, scale: Precision) @This() {
            assert(shape >= 0);
            assert(scale >= 0);
            return .{
                .shape = shape,
                .scale = scale,
                .exp = Exponential(Precision).init(1.0),
                .interface = PDist{
                    .vtable = &.{ .sample = sampleImpl, .format = formatImpl },
                },
            };
        }

        /// To parse the JSON into the UnionDistr, it's needed to ignore the
        /// .interface method when parsing the json to create the union!
        pub fn jsonParse(
            gpa: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const Params = struct { shape: Precision, scale: Precision };

            const parsed = try std.json.innerParse(Params, gpa, source, options);

            return init(parsed.shape, parsed.scale);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Pareto{{alpha={d:.2}, x_m={d:.2}}}", .{ self.shape, self.scale });
        }
    };
}
