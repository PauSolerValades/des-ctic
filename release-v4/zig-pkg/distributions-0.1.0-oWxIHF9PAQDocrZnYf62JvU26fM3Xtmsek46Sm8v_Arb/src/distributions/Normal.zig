const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;

const Distribution = @import("../Distribution.zig").Distribution;
const ziggurat = @import("../ziggurat.zig").ziggurat;
const table = @import("../tables.zig");
const uniform = @import("Uniform.zig");
const Uniform = uniform.Uniform;
const Interval = uniform.Interval;

/// Implements the normal distribution
/// $ f(x) = 1 / sigma sqrt(2*pi) * exp{ - (x - mu)^2 / 2 sigma^2 $
/// The sampling method is XOR Ziggurat
pub fn Normal(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        mean: Precision,
        variance: Precision,
        interface: PDist,

        unif: Uniform(Precision),

        /// Uses Ziggurat
        pub fn sample(self: *const Self, rng: Random) Precision {
            const u: Precision = ziggurat(Precision, rng, &table.NormalTable(Precision), pdfStandard, zeroCase, true);
            return (u * self.variance) + self.mean;
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn init(mean: Precision, variance: Precision) @This() {
            return .{
                .mean = mean,
                .variance = variance,
                .unif = .init(0, 1, Interval.oo),
                .interface = PDist{
                    .vtable = &.{ .sample = sampleImpl, .format = formatImpl },
                },
            };
        }

        pub fn zeroCase(rng: Random, u: Precision) Precision {
            var x: Precision = 1.0;
            var y: Precision = 0.0;

            const unif: Uniform(Precision) = .init(0, 1, Interval.oo);
            while (-2.0 * y < x * x) {
                const x_ = unif.sample(rng);
                const y_ = unif.sample(rng);

                x = @log(x_) / table.zigguratNormalR(Precision);
                y = @log(y_);
            }

            if (u < 0.0) {
                return x - table.zigguratNormalR(Precision);
            } else {
                return table.zigguratNormalR(Precision) - x;
            }
        }

        pub fn pdfStandard(x: Precision) Precision {
            const pi = std.math.pi;
            const exp = std.math.exp;
            return (1.0 / @sqrt(2 * pi)) * exp(-(x * x) / 2.0);
        }

        pub fn normPdf(mean: Precision, variance: Precision, x: Precision) Precision {
            const pi = std.math.pi;
            const exp = std.math.exp;

            const coefficient = 1 / (@sqrt(2 * pi * variance));
            const exponent = -(x - mean) * (x - mean) / (2.0 * variance);
            return coefficient * exp(exponent);
        }

        pub fn pdf(self: *const Self, x: Precision) Precision {
            return normPdf(self.mean, self.variance, x);
        }

        fn cdfStandard(x: f64) f64 {
            if (x < 0.0) return 1.0 - cdfStandard(-x);

            const p = 0.2316419;
            const b1 = 0.319381530;
            const b2 = -0.356563782;
            const b3 = 1.781477937;
            const b4 = -1.821255978;
            const b5 = 1.330274429;

            const t = 1.0 / (1.0 + p * x);

            const poly = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))));

            return 1.0 - pdfStandard(x) * poly;
        }

        pub fn normCdf(mean: Precision, variance: Precision, x: Precision) Precision {
            const z = (x - mean) / @sqrt(variance);
            return cdfStandard(z);
        }

        /// Instance method for your anytype ksTestCont
        pub fn cdf(self: *const Self, x: Precision) Precision {
            return normCdf(self.mean, self.variance, x);
        }

        /// To parse the JSON into the UnionDistr, it's needed to ignore the
        /// .interface method when parsing the json to create the union!
        pub fn jsonParse(
            gpa: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const Params = struct { mean: Precision, variance: Precision };

            const parsed = try std.json.innerParse(Params, gpa, source, options);

            return init(parsed.mean, parsed.variance);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Normal{{μ={d:.2}, σ²={d:.2}}}", .{ self.mean, self.variance });
        }
    };
}
