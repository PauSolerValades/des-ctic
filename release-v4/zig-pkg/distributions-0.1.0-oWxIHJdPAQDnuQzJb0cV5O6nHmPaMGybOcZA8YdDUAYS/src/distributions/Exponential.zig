const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const exp = std.math.exp;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;
const ziggurat = @import("../ziggurat.zig").ziggurat;
const table = @import("../tables.zig");

/// Implements the rate ($EE (X) = lambda$) exponential distribution.
/// $ f(x) = lambda*e^(-lambda x) $
/// It samples using the Ziggurat XOR method.
pub fn Exponential(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        rate: Precision,
        interface: PDist,

        pub fn init(rate: Precision) @This() {
            assert(rate >= 0);
            return .{ .rate = rate, .interface = PDist{ .vtable = &.{
                .sample = sampleImpl,
                .format = formatImpl,
            } } };
        }

        pub fn initMean(mean: Precision) @This() {
            assert(mean >= 0);
            return .{ .rate = 1.0 / mean, .interface = PDist{ .vtable = &.{
                .sample = sampleImpl,
                .format = formatImpl,
            } } };
        }

        /// Uses Ziggurat
        pub fn sample(self: *const Self, rng: Random) Precision {
            const u: Precision = ziggurat(Precision, rng, &table.ExponentialTable(Precision), pdfStandard, zeroCase, false);
            return u / self.rate;
        }

        /// Uses the inverse method RNG
        pub fn sampleInv(self: *const Self, rng: Random) Precision {
            const u = rng.float(Precision);
            return (1.0 / self.rate) * (-@log(u));
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn zeroCase(rng: Random, e: Precision) Precision {
            _ = e;
            return table.zigguratExponentialR(Precision) - @log(rng.float(Precision));
        }

        pub fn pdfStandard(x: Precision) Precision {
            return expPdf(1, x);
        }

        pub fn expPdf(rate: Precision, x: Precision) Precision {
            return rate * exp(-rate * x);
        }

        pub fn expCdf(rate: Precision, x: Precision) Precision {
            return 1 - exp(-rate * x);
        }

        pub fn cdf(self: *const Self, x: Precision) Precision {
            return expCdf(self.rate, x);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Exp{{λ={d:.2}}}", .{self.rate});
        }

        /// To parse the JSON into the UnionDistr, it's needed to ignore the
        /// .interface method when parsing the json to create the union!
        pub fn jsonParse(
            gpa: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const Params = struct {
                rate: ?Precision = null,
                mean: ?Precision = null,
            };

            const parsed = try std.json.innerParse(Params, gpa, source, options);

            if (parsed.rate) |r| {
                if (parsed.mean != null) return error.UnexpectedToken;

                return init(r);
            } else if (parsed.mean) |m| {
                return initMean(m);
            } else {
                return error.MissingField;
            }
        }
    };
}
