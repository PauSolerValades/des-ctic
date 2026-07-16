const std = @import("std");
const Io = std.Io;

const stats = @import("distributions");

const P: type = f32;

const Exp = stats.Exponential(f32);
const Norm = stats.Normal(f32);
const Dist = stats.Distribution(f32);

pub fn main(init: std.process.Init) !void {
    //const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    
    const seed = blk: {
        var os_seed: u64 = undefined;
        init.io.random(std.mem.asBytes(&os_seed));
        break :blk os_seed;
    };

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const exp: Exp = .init(2); 
    const dexp: *const Dist = &exp.interface; //ptr distribution
    const e = dexp.sample(rng);
   
    var esample: [40]f32 = undefined;
    dexp.sampleBuffer(&esample, rng);

    try stdout_writer.print("Exponential sample: {d}\n", .{e});
    try stdout_writer.print("Exponential Buffer {any}\n", .{esample});
   
    const norm: Norm = .init(0,1); 
    const dnorm: *const Dist = &norm.interface; //ptr distribution
    const u = dnorm.sample(rng);
   
    var nsample: [40]f32 = undefined;
    dnorm.sampleBuffer(&nsample, rng);

    try stdout_writer.print("Normal sample: {d}\n", .{u});
    try stdout_writer.print("Normal Buffer {any}\n", .{nsample});
   

    try stdout_writer.flush();
}


