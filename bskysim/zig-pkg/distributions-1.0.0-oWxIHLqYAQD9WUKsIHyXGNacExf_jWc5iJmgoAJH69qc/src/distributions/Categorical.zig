const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Distribution = @import("../Distribution.zig").Distribution;

/// Implementation of the Categorical Distribution:
/// $ P(X = i) = p_i
pub fn Categorical(comptime Precision: type, comptime DataType: type) type {
    const weightsInfo = @typeInfo(Precision);

    if (weightsInfo != .float) @compileError("Weights must be a floating point type");

    return struct {
        const Self = @This();
        const PDist: type = Distribution(DataType);

        weights: []const Precision,
        data: []const DataType,
        acc: []const Precision,
        interface: PDist,

        pub fn init(gpa: Allocator, weights: []const Precision, data: []const DataType) !Self {
            assert(weights.len == data.len);

            var acc = try gpa.alloc(Precision, weights.len);
            var sum: Precision = 0.0;
            for (weights, 0..) |weight, i| {
                sum += weight;
                acc[i] = sum;
            }

            // being very pedantic about error propagation :)
            const tol = @as(Precision, @floatFromInt(weights.len)) * std.math.floatEps(Precision);
            assert(std.math.approxEqRel(Precision, sum, 1.0, tol));

            return .{ .weights = weights, .acc = acc, .data = data, .interface = .{ .vtable = &.{ .sample = sampleImpl, .format = formatImpl } } };
        }

        pub fn deinit(self: *const Self, gpa: Allocator) void {
            gpa.free(self.acc);
        }

        // uses the rng instance to get a float between 0 and 1 and then scales it
        pub inline fn sample(self: *const Self, rng: Random) DataType {
            const u = rng.float(Precision);
            var i: usize = 0;
            for (self.acc) |a| {
                if (u <= a) break;
                i += 1;
            }
            return self.data[i];
        }

        /// Function to put into the VTable of Distribution
        fn sampleImpl(dist: *const PDist, rng: Random) DataType {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        // Example: Categorical( (1, 0.1, 0.1), (2, 0.1, 0.2), (3, 0.1, 0.3) )
        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            try writer.writeAll("Categorical{{ ");

            for (0..self.weights.len) |i| {
                try self.formatEntry(writer, i);
            }
            try writer.writeAll("}}");
        }

        // Printing ladder: exact interface -> vtable, duck-typed format -> call it, otherwise index
        fn formatEntry(self: *const Self, writer: *Io.Writer, i: usize) !void {
            const duck_format = comptime switch (@typeInfo(DataType)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(DataType, "format"),
                else => false,
            };
            if (duck_format) {
                try self.data[i].format(writer);
            } else switch (@typeInfo(DataType)) {
                .pointer, .array => try writer.print("({s}, {d:.2}, {d:.2}) ", .{ self.data[i], self.weights[i], self.acc[i] }),
                .@"enum" => try writer.print("({t}, {d:.2}, {d:.2}) ", .{ self.data[i], self.weights[i], self.acc[i] }),
                .int, .float => try writer.print("({d:.2}, {d:.2}, {d:.2}) ", .{ self.data[i], self.weights[i], self.acc[i] }),
                else => try writer.print("(#{d}, {d:.2}, {d:.2}) ", .{ i, self.weights[i], self.acc[i] }),
            }
        }
    };
}
