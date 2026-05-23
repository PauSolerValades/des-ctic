const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const eql = std.mem.eql;
const Io = std.Io;

const argz = @import("eazy_args");

const structs = @import("config.zig");

const simulation = @import("simulation.zig");

const loader = @import("json_loading.zig");
const gn = @import("graph_network.zig");
const entities = @import("entities.zig");

const Distribution = structs.Distribution;
const SimConfig = structs.SimConfig;
const SimResults = structs.SimResults;

const User = simulation.User;
const Post = simulation.Post;
const TimelineEvent = simulation.TimelineEvent;

const Arg = argz.Argument;
const ParseErrors = argz.ParseErrors;

const def = .{
    .name = "v4",
    .description = "Bsky sim",
    .required = .{
        Arg([]const u8, "data", "Data file containing the network definition"),
    },
};

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &bufferr);
    const stderr = &stderr_writer.interface;

    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const cwd = Io.Dir.cwd();

    var iter = init.minimal.args.iterate();
    const args = argz.parseArgsPosix(def, &iter, stdout, stderr) catch |err| {
        switch (err) {
            ParseErrors.HelpShown => try stdout.flush(),
            else => try stderr.flush(),
        }
        std.process.exit(0);
    };

    var arena_json: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const data_alloc = arena_json.allocator();

    const config = try SimConfig.calibrate(gpa);
    defer config.deinit(gpa);

    const startTimeLoadData = Io.Timestamp.now(init.io, .real);
    // const loaded_data = try loader.loadJson(arena, init.io, args.data, loader.NetworkJson);
    const loaded_data = loader.loadJson(data_alloc, init.io, args.data, loader.NetworkJson) catch |err| {
        try stderr.print("Error parsing data JSON: {any}", .{err});
        try stderr.flush();
        std.process.exit(0);
    };
    const elapsedTimeLoadData = startTimeLoadData.untilNow(init.io, .real);

    try stdout.print("Time Elapsed Loading Data: {d} ms\n", .{elapsedTimeLoadData.toMilliseconds()});
    try stdout.flush();

    const seed = if (config.seed) |s| s else blk: {
        var os_seed: u64 = undefined;
        init.io.random(std.mem.asBytes(&os_seed));
        break :blk os_seed;
    };

    var prng = Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const startTimeWireData = Io.Timestamp.now(init.io, .real);
    var graph: gn.Topology = try .create(init.io, gpa, arena, rng, loaded_data.value);
    defer graph.delete(gpa, arena);
    const elapsedTimeWireData = startTimeWireData.untilNow(init.io, .real);

    // the lifetime of this data ends here
    var loaded_data_mut = loaded_data;
    loaded_data_mut.deinit();
    arena_json.deinit();

    try stdout.print("Time Elapsed Wiring Data: {d} ms\n", .{elapsedTimeWireData.toMilliseconds()});
    try stdout.flush();

    try stdout.writeAll("Loaded configuration\n");
    try stdout.print("{f}\n", .{config});
    try stdout.flush();

    try stdout.writeAll("Running the simulation once\n");
    try stdout.flush();

    // create the results folder
    // cwd.access(init.io, "results", .{}) catch |err| switch (err) {
    //     error.FileNotFound => try cwd.createDir(init.io, "results", .{ .mode = Oo755} ),
    //     else => return err,
    // };

    // const timestamp = Io.Clock.real.now(init.io);
    // buffers to hold the formatted file paths to avoid dynamic memory
    // var trace_path_buffer: [256]u8 = undefined;
    // const traca_path = try std.fmt.bufPrint(&traca_path_buffer, "traca_{d}.txt", .{timestamp});

    const action_name = "action_trace.bin";
    const session_name = "session_trace.bin";
    const create_name = "create_trace.bin";
    const propagation_name = "propagation_trace.bin";

    var action_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const action_path = try std.fmt.bufPrint(&action_path_buf, "results/{s}", .{action_name});

    var session_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_path_buf, "results/{s}", .{session_name});

    var create_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const create_path = try std.fmt.bufPrint(&create_path_buf, "results/{s}", .{create_name});

    var prop_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prop_path = try std.fmt.bufPrint(&prop_path_buf, "results/{s}", .{propagation_name});

    var action_buffer: [64 * 1024]u8 = undefined;
    var session_buffer: [64 * 1024]u8 = undefined;
    var create_buffer: [64 * 1024]u8 = undefined;
    var propagation_buffer: [64 * 1024]u8 = undefined;

    const action_file = try cwd.createFile(init.io, action_path, .{ .read = false });
    var action_file_writer = action_file.writer(init.io, &action_buffer);
    const action_writer = &action_file_writer.interface;

    const session_file = try cwd.createFile(init.io, session_path, .{ .read = false });
    var session_file_writer = session_file.writer(init.io, &session_buffer);
    const session_writer = &session_file_writer.interface;

    const create_file = try cwd.createFile(init.io, create_path, .{ .read = false });
    var create_file_writer = create_file.writer(init.io, &create_buffer);
    const create_writer = &create_file_writer.interface;

    const prop_file = try cwd.createFile(init.io, prop_path, .{ .read = false });
    var prop_file_writer = prop_file.writer(init.io, &propagation_buffer);
    const prop_writer = &prop_file_writer.interface;

    const startTime = Io.Timestamp.now(init.io, .real);
    const results = try simulation.simulate(
        gpa,
        arena,
        rng,
        &config,
        &graph,
        action_writer,
        session_writer,
        create_writer,
        prop_writer,
    );
    const elapsedTime = startTime.untilNow(init.io, .real);

    try stdout.print("{f}\n", .{results});
    try stdout.print("Time Elapsed: {d} ms\n", .{elapsedTime.toMilliseconds()});
    try stdout.flush();

    try stdout.writeAll("Converting the traces into JSONL\n");
    try bytesToJsonl(init.io, entities.TraceAction, action_path, "results/action_trace.jsonl");
    try bytesToJsonl(init.io, entities.TraceSession, session_path, "results/session_trace.jsonl");
    try bytesToJsonl(init.io, entities.TraceCreate, create_path, "results/create_trace.jsonl");
    try bytesToJsonl(init.io, entities.TracePropagation, prop_path, "results/propagate_trace.jsonl");

    try stdout.flush();
}

/// this probably could be much more prettier if I passed the Io.Writer/Io.Reader by parameter, and I
/// could even reuse the buffers... but dunno, at least this is pretty efficient :D
fn bytesToJsonl(io: Io, comptime T: type, read_file: []const u8, write_file: []const u8) !void {
    const n = @sizeOf(T);

    var jsonl_buffer: [4 * 1024]u8 = undefined;
    const jsonl_file = try Io.Dir.cwd().createFile(io, write_file, .{ .read = false });
    var jsonl_file_writer = jsonl_file.writer(io, &jsonl_buffer);
    const writer = &jsonl_file_writer.interface;

    if (Io.Dir.cwd().openFile(io, read_file, .{})) |file| {
        var buf: [4 * 1024]u8 = undefined;
        var reader: Io.File.Reader = file.reader(io, &buf);
        const ri = &reader.interface;

        while (true) {
            const bytes = ri.take(n) catch |err| {
                switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return reader.err.?,
                }
            };

            const event = std.mem.bytesAsValue(T, bytes);
            try std.json.Stringify.value(event, .{}, writer);
            try writer.writeAll("\n");
        }
    } else |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            std.debug.print("unable to open file: {}\n", .{err});
        },
        else => |e| return e, // don't continue; rather, bomb out
    }

    try writer.flush();
}
