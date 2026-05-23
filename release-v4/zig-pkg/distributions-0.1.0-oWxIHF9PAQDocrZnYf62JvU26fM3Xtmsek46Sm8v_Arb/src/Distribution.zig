const std = @import("std");
const Random = std.Random;
const Io = std.Io;

pub fn VTable(comptime Precision: type) type {
    return struct {
        sample: *const fn (dist: *const Distribution(Precision), rng: Random) Precision,
        format: *const fn (dist: *const Distribution(Precision), writer: *Io.Writer) std.Io.Writer.Error!void,
    };
}

pub fn Distribution(comptime Precision: type) type {
    
    return struct {
        const Self = @This();
        vtable: *const VTable(Precision),

        pub inline fn sample(self: *const Self, rng: Random) Precision {
            return self.vtable.sample(self, rng);
        }
    
        // here should go common functions that behave the same for all the functionalities
        // that is, for example, fill a buffer with n samples. samples has to be the implemented
        // and the nSamples is here and just calls samples.

        pub inline fn format(self: *const Self, writer: *Io.Writer) !void {
            try self.vtable.format(self, writer);
        }

        pub inline fn sampleBuffer(self: *const Self, buffer: []Precision, rng: Random) void {
            for (0..buffer.len) |i| {
                buffer[i] = self.vtable.sample(self, rng);
            }
        }
    };
}

