const std = @import("std");
const Random = std.Random;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Categorical = @import("Categorical.zig").Categorical;
const Distribution = @import("../Distribution.zig").Distribution;

pub fn Mixture(comptime Precision: type, comptime Dist: type) type {
    if (!@hasDecl(Dist, "sample")) @compileError("Dist must have a sample function. If you are using a distribution not in the library please check.");

    return struct {
        const Data = @typeInfo(@TypeOf(Dist.sample)).@"fn".return_type.?;
        const PDist: type = Distribution(Data);
        const Self = @This();

        cat: Categorical(Precision, Dist),
        interface: PDist,

        pub fn init(gpa: Allocator, weights: []const Precision, distributions: []const Dist) !Self {
            const cat: Categorical(Precision, Dist) = try .init(gpa, weights, distributions);

            return .{
                .cat = cat,
                .interface = .{
                    .vtable = &.{ .sample = sampleImpl, .format = formatImpl },
                },
            };
        }

        pub fn deinit(self: *const Self, gpa: Allocator) void {
            self.cat.deinit(gpa);
        }
        pub fn sample(self: *const Self, rng: Random) Data {
            const d = self.cat.sample(rng);
            return d.sample(rng);
        }

        pub fn sampleImpl(dist: *const Distribution(Data), rng: Random) Data {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try self.cat.format(writer);
        }
    };
}

test "Trying this shit out" {
    const seed: u64 = 0xDEAD_BEEF;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const ta = std.testing.allocator;

    const Normal = @import("Normal.zig").Normal;

    const n1: Normal(f32) = .init(1, 2);
    const n2: Normal(f32) = .init(5, 2);
    const data = [_]Normal(f32){ n1, n2 };
    const weights = [_]f32{ 0.9, 0.1 };

    const mixture: Mixture(f32, Normal(f32)) = try .init(ta, &weights, &data);
    defer mixture.deinit(ta);
    _ = mixture.sample(rng);
    _ = mixture.sample(rng);
    _ = mixture.sample(rng);
    _ = mixture.sample(rng);

    try std.testing.expect(1 == 1);
}

test "mixture of two ECDFs" {
    const seed: u64 = 0xDEAD_BEEF;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const ta = std.testing.allocator;

    const ECDF = @import("ECDF.zig").ECDF;

    var d1 = [_]f64{ 1, 2, 3 };
    var d2 = [_]f64{ 10, 20 };
    const e1 = try ECDF(f64, f64).init(ta, &d1);
    defer e1.deinit(ta);
    const e2 = try ECDF(f64, f64).init(ta, &d2);
    defer e2.deinit(ta);

    const components = [_]ECDF(f64, f64){ e1, e2 };
    const weights = [_]f64{ 0.5, 0.5 };

    const mixture: Mixture(f64, ECDF(f64, f64)) = try .init(ta, &weights, &components);
    defer mixture.deinit(ta);

    var saw_low = false;
    var saw_high = false;
    for (0..200) |_| {
        const x = mixture.sample(rng);
        // every sample must come from one of the two ECDFs
        try std.testing.expect(x == 1 or x == 2 or x == 3 or x == 10 or x == 20);
        if (x <= 3) saw_low = true;
        if (x >= 10) saw_high = true;
    }
    try std.testing.expect(saw_low and saw_high); // both components get picked
}
