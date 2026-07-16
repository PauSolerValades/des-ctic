const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;
const Io = std.Io;

const Distribution = @import("../Distribution.zig").Distribution;

/// Implementation of a constant:
/// $ f(x) = c $
/// $ F(x) = cx $
pub fn Constant(comptime Precision: type) type {
    
    return struct {
        const Self = @This(); // = Uniform(Precision)
        const PDist: type = Distribution(Precision);

        value: Precision,
        interface: PDist,
        
        pub fn init(c: Precision) Self {
            return .{
                .value = c,
                .interface = .{ .vtable = &.{ .sample = sampleImpl, .format = formatImpl } }
            };
        }

        // uses the rng instance to get a float between 0 and 1 and then scales it
        pub inline fn sample(self: *const Self, rng: Random) Precision {
            _ = rng;
            return self.value;
        }

        /// Function to put into the VTable of Distribution
        fn sampleImpl(dist: *const PDist, rng: Random) Precision {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }
    
        pub fn constCdf(value: Precision, x: Precision) Precision {
            return value * x;
        }

        pub fn cdf(self: *const Self, x: Precision) Precision {
            return constCdf(self.value, x);
        }
                
        pub fn jsonParse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const Params = struct { value: Precision };

            const parsed = try std.json.innerParse(Params, gpa, source, options);

            return init(parsed.value);
        }
        
        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }


        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.print("Const{{c={d:.2}}}", .{self.value});
        }
    };
}

