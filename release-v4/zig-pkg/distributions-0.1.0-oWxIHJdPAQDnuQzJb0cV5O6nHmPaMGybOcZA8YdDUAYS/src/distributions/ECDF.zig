const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Distribution = @import("../Distribution.zig").Distribution;

/// Empirical Cumulative Distribution Function. (https://en.wikipedia.org/wiki/Empirical_distribution_function)
/// Given data, s
pub fn ECDF(comptime Precision: type, comptime DataType: type) type {

    const Bin = struct {
        value: DataType,
        cump: Precision,
    };

    return struct {
        const Self = @This();
        const PDist: type = Distribution(DataType);
       
        bins: std.MultiArrayList(Bin),
        interface: PDist,
       
        /// Create an ECDF object.
        /// Defined for enum (with the number assigned to them), booleans (false < true), int and float.
        /// Iterates over the list and counts which and how many different numbers are on the data.
        /// Then computes the probabilites of each element and its cumsum.
        pub fn init(gpa: Allocator, data: []DataType) !Self {
            assert(data.len != 0); 

            switch(@typeInfo(DataType)) {
                .@"enum" => {
                    const Sorter = struct {
                        fn lessThan(_: void, a: DataType, b: DataType) bool {
                            return @intFromEnum(a) < @intFromEnum(b);
                        }
                    };
                    std.mem.sort(DataType, data, {}, comptime Sorter.lessThan);
                },
                .bool => {
                    const Sorter = struct {
                        fn lessThan(_: void, a: DataType, b: DataType) bool {
                            return @intFromBool(a) < @intFromBool(b);
                        }
                    };
                    std.mem.sort(DataType, data, {}, comptime Sorter.lessThan);
                },
                .int, .float => std.mem.sort(DataType, data, {}, comptime std.sort.asc(DataType)),
                else => @compileError("Type not supported for ECDF"), 
            }
          
            var count: ArrayList(usize) = .empty;
            var values: ArrayList(DataType) = .empty;
            
            defer {
                count.deinit(gpa);
                values.deinit(gpa);
            }

            // count how many elements are in the data 
            var c: usize = 1;
            for (1..data.len) |i| {
                if (data[i-1] == data[i]) { 
                    c += 1;
                } else {
                    try count.append(gpa, c);
                    try values.append(gpa, data[i-1]);
                    c = 1;
                }
            }
            // Process the final element
            try count.append(gpa, c);
            try values.append(gpa, data[data.len-1]);

            var bins: std.MultiArrayList(Bin) = try .initCapacity(gpa, values.items.len);
            
            const totalf: Precision = @floatFromInt(data.len);
            var cumulative_sum: usize = 0;

            for (count.items, 0..) |n, i| {
                cumulative_sum += n;
                const nf: Precision = @floatFromInt(cumulative_sum);
                bins.appendAssumeCapacity(Bin{ .cump = nf / totalf, .value = values.items[i] });
            }

            return .{
                .bins = bins,
                .interface = .{ .vtable = &.{ .sample = sampleImpl, .format = formatImpl } }
            };
        }

        pub fn deinit(self: *const Self, gpa: Allocator) void {
            // to trick the compiler to make the ECDF immutable
            // we make a copy of the self and free it.
            var mutable_bins = self.bins;
            mutable_bins.deinit(gpa);
        }

        /// generates a random [0,1] and returns the first number bigger than it    
        /// uses binary search to get sweet O(log(n))
        pub inline fn sample(self: *const Self, rng: Random) DataType {
            const u = rng.float(Precision);
            
            var lower: usize = 0;
            var upper: usize = self.bins.len;

            while (lower < upper) {
                const i = lower + @divFloor(upper - lower, 2);
                const p = self.bins.items(.cump)[i];
                
                if (u <= p) {
                    upper = i;
                } else if (u > p) {
                    lower = i + 1;
                }
            }
        
            return self.bins.items(.value)[lower];
        }

        /// Function to put into the VTable of Distribution
        fn sampleImpl(dist: *const PDist, rng: Random) DataType {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            return self.sample(rng);
        }

        pub fn cdf(self: *const Self, x: Precision) Precision {
            var lower: usize = 0;
            var upper: usize = self.bins.len;

            while (lower < upper) {
                const i = lower + @divFloor(upper - lower, 2);
                const p = self.bins.items(.cump)[i];
                
                if (x <= p) {
                    upper = i;
                } else if (x > p) {
                    lower = i + 1;
                }
            }
        
            return self.bins.items(.cump)[lower];
        }

                
        pub fn jsonParse(
            gpa: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            const Params = struct { data: []DataType };

            const parsed = try std.json.innerParse(Params, gpa, source, options);

            return init(gpa, parsed.data);
        }

        fn formatImpl(dist: *const PDist, writer: *Io.Writer) !void {
            const self: *const Self = @alignCast(@fieldParentPtr("interface", dist));
            try self.format(writer);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) !void {
            const values = self.bins.items(.value);
            const cump = self.bins.items(.cump);

            try writer.writeAll("ECDF{{ ");
            for (0..values.len - 1) |i| {
                try writer.print("({d:.2}, {d:.2}, {d:.2}) ", .{values[i], cump[i+1] - cump[i], cump[i]});
            }
            const last_i = values.len - 1;
            try writer.print("({d:.2}, {d:.2}, {d:.2}) }}\n", .{values[last_i], cump[last_i], cump[last_i]});
        }

    };
}

const ta = std.testing.allocator;
const expectEqualSlices = std.testing.expectEqualSlices;

test "test" {

    var data = [_]u32{0,0,1,1,2,2,3,3};

    const ecdf: ECDF(f32, u32) = try .init(ta, &data);
    defer ecdf.deinit(ta);

    const values = [_]u32{0,1,2,3};
    const cump = [_]f32{0.25, 0.50, 0.75, 1};

    try expectEqualSlices(u32, ecdf.bins.items(.value), &values);
    try expectEqualSlices(f32, ecdf.bins.items(.cump), &cump);
}
