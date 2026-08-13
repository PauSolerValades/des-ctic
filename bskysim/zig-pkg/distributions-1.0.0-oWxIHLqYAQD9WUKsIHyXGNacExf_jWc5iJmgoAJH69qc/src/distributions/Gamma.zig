const std = @import("std");
const Random = std.Random;
const Io = std.Io;
const math = std.math;
const assert = std.debug.assert;

const Distribution = @import("../Distribution.zig").Distribution;
const Normal = @import("Normal.zig").Normal;

/// Implements the gamma distribution with shape $k$ and scale $theta$.
/// $ f(x) = x^(k-1) * e^(-x/theta) / (Gamma(k) * theta^k) $
/// Sampling uses the Marsaglia–Tsang method.
pub fn Gamma(comptime Precision: type) type {
    return struct {
        pub const Self = @This();
        pub const PDist = Distribution(Precision);

        shape: Precision, // k
        scale: Precision, // theta
        interface: PDist,
        norm: Normal(Precision),

        pub fn init(shape: Precision, scale: Precision) @This() {
            assert(shape > 0 and !math.isNan(shape) and !math.isInf(shape));
            assert(scale > 0 and !math.isNan(scale) and !math.isInf(scale));
            return .{ .shape = shape, .scale = scale, .interface = PDist{ .vtable = &.{
                .sample = sampleImpl,
                .format = formatImpl,
            } }, .norm = Normal(Precision).init(0, 1) };
        }

        /// Marsaglia & Tsang; for shape < 1 boost to (shape + 1) and thin with u^(1/k)
        pub fn sample(self: *const Self, rng: Random) Precision {
            const eff_shape = if (self.shape < 1) 1 + self.shape else self.shape;

            const d = eff_shape - 1.0 / 3.0;
            const c = (1.0 / 3.0) / @sqrt(d);

            var x: Precision = undefined;
            var v: Precision = undefined;

            while (true) {
                x = self.norm.sample(rng);
                v = 1 + c * x;
                if (v <= 0) continue;

                v = v * v * v;
                const u = rng.float(Precision);

                // quick squeeze test
                if (u < 1 - 0.0331 * x * x * x * x) break;

                // exact test
                if (@log(u) < 0.5 * x * x + d * (1 - v + @log(v))) break;
            }

            var result = self.scale * d * v;

            if (self.shape < 1) {
                result *= math.pow(Precision, rng.float(Precision), 1 / self.shape);
            }

            return result;
        }

        pub fn sampleImpl(dist: *const Distribution(Precision), rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        /// Log-density evaluated in log-space to prevent underflow/overflow.
        pub fn lnPdf(self: *const Self, x: Precision) Precision {
            assert(x >= 0);

            if (x == 0) {
                if (self.shape == 1) return -@log(self.scale);
                return if (self.shape < 1) math.inf(Precision) else -math.inf(Precision);
            }

            return (self.shape - 1) * @log(x) - x / self.scale -
                self.shape * @log(self.scale) - math.lgamma(Precision, self.shape);
        }

        pub fn pdf(self: *const Self, x: Precision) Precision {
            assert(x >= 0);
            return @exp(self.lnPdf(x));
        }

        pub fn cdf(self: *const Self, x: Precision) Precision {
            if (x <= 0) return 0;
            return gammaP(self.shape, x / self.scale);
        }

        /// Regularized lower incomplete gamma P(a, x): series for x < a+1,
        /// continued fraction (for Q, with P = 1 − Q) otherwise.
        /// Numerical Recipes §6.2.
        fn gammaP(a: Precision, x: Precision) Precision {
            const eps = 10 * math.floatEps(Precision);
            const gln = math.lgamma(Precision, a);

            if (x < a + 1) {
                var ap = a;
                var sum = 1 / a;
                var del = sum;
                for (0..100) |_| {
                    ap += 1;
                    del *= x / ap;
                    sum += del;
                    if (@abs(del) < @abs(sum) * eps) break;
                }
                return sum * @exp(-x + a * @log(x) - gln);
            } else {
                const fpmin = math.floatMin(Precision) / eps;
                var b = x + 1 - a;
                var c = 1 / fpmin;
                var d = 1 / b;
                var h = d;
                for (1..101) |i| {
                    const fi: Precision = @floatFromInt(i);
                    const an = -fi * (fi - a);
                    b += 2;
                    d = an * d + b;
                    if (@abs(d) < fpmin) d = fpmin;
                    c = b + an / c;
                    if (@abs(c) < fpmin) c = fpmin;
                    d = 1 / d;
                    const del = d * c;
                    h *= del;
                    if (@abs(del - 1) < eps) break;
                }
                return 1 - @exp(-x + a * @log(x) - gln) * h;
            }
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Gamma{{α={d:.2}, θ={d:.2}}}", .{ self.shape, self.scale });
        }
    };
}
