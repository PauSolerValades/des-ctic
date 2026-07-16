const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;
const table = @import("../tables.zig");
const uniform = @import("Uniform.zig");
const Uniform = uniform.Uniform;
const Interval = uniform.Interval;

/// Implements the normal distribution
/// $ f(x) = 1 / sigma sqrt(2*pi) * exp{ - (x - mu)^2 / 2 sigma^2 $
/// The sampling method is XOR Ziggurat
pub fn Pareto(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        shape: Precision, // alpha
        scale: Precision, // x_m
        interface: PDist,
        unif: Uniform(Precision),

        /// Uses Ziggurat
        pub fn sample(self: *const Self, rng: Random) Precision {
            return self.shape * self.unif.sample(rng) * std.math.exp(self.scale);
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
                .unif = .init(0, 1, Interval.oc),
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
