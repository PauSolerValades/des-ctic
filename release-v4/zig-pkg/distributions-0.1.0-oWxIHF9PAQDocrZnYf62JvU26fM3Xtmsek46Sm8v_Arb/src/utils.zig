const std = @import("std");

/// Compares two Samples and returns std.math.Order (.lt, .eq, .gt)
fn cmp(a: Sample, b: Sample) std.math.Order {
    if (Sample == []const u8) {
        return std.mem.order(u8, a, b);
    }

    switch (@typeInfo(Sample)) {
        .int, .float => return std.math.order(a, b),
        .bool => return std.math.order(@intFromBool(a), @intFromBool(b)),
        .@"enum" => return std.math.order(@intFromEnum(a), @intFromEnum(b)),
        else => @compileError("Type not supported for ECDF comparison"),
    }
}
