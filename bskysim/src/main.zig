const std = @import("std");
const Random = std.Random;
const Io = std.Io;

const argz = @import("eazy_args");

const structs = @import("config.zig");
const simulation = @import("simulation.zig");
const loader = @import("load-topology.zig");
const entities = @import("entities.zig");
const topo = @import("topology.zig");
const traces = @import("traces.zig");

const SimConfig = structs.SimConfig;

const Topology = topo.Topology;
const SimState = topo.SimState;

const Arg = argz.Argument;
const Opt = argz.Option;
const Flag = argz.Flag;

const ParseErrors = argz.ParseErrors;

const def = .{
    .name = "specific",
    .description = "Bskysim with the configuration struct known at compile time",
    .required = .{
        Arg([]const u8, "data", "Data file containing the network definition"),
        Arg([]const u8, "config", "Input parameters"),
    },
    .options = .{
        Opt([]const u8, "output", "o", "./traces", "Dataset name for trace folder"),
        Opt(usize, "runs", "n", 1, "Runs to execute the simulation"),
        Opt(usize, "workers", "w", 1, "Units of parallelism"),
    },
    .flags = .{
        Flag("clean", "c", "Delete the .bin output"),
        Flag("skipjsonl", "s", "Don't convert to JSONL"),
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

    if (args.clean and args.skipjsonl) {
        try stdout.writeAll("Flags -c/--clean and -s/--skipjsonl are mutually exclusive");
        try stdout.flush();
        std.process.exit(0);
    }

    var arena_json: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const data_alloc = arena_json.allocator();

    const len = args.config.len;
    if (std.mem.eql(u8, args.config[len - 5 .. len - 1], ".json")) {
        try stderr.print("The provided config file ({s}) does not have a 'json' extension\n", .{args.config});
        std.process.exit(1);
    }

    //TODO: use a buffer as we know how long this is going to be
    const content = Io.Dir.cwd().readFileAlloc(init.io, args.config, gpa, .unlimited) catch |err| {
        switch (err) {
            error.FileNotFound => try stderr.print("Config file {s} is not found.\n", .{args.config}),
            error.IsDir => try stderr.print("{s} is a directory.\n", .{args.config}),
            else => try stderr.print("Unexpected error: {}", .{err}),
        }
        std.process.exit(0);
    };
    defer gpa.free(content);

    const config: SimConfig = SimConfig.create(gpa, content, stderr) catch |err| {
        switch (err) {
            error.OutOfMemory => try stderr.writeAll("Out of memory while parsing config.\n"),
            error.WriteFailed => {}, // stderr already dead, nothing to do
            error.InvalidCharacter => try stderr.writeAll("Invalid number in config file.\n"),
            // JsonScannerError: JSON structure is malformed
            error.UnexpectedToken, error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun => try stderr.writeAll("Invalid JSON config file.\n"),
            // ParseError: diagnostic already printed by the parser
            error.UnknownDistribution, error.UnknownParameter, error.MissingField, error.InvalidInterval, error.InvalidField => {},
        }
        try stderr.flush();
        std.process.exit(1);
    };
    defer config.delete(gpa);
    try stderr.flush(); // if a warning happens

    //TODO: dump current config into the output folder with stringify

    const startTimeLoadData = Io.Timestamp.now(init.io, .real);
    const sampled_topology = try loader.BinaryGraph.create(init.io, data_alloc, args.data);
    const elapsedTimeLoadData = startTimeLoadData.untilNow(init.io, .real);

    try stdout.print("Time Elapsed Loading Data: {d} ms\n", .{elapsedTimeLoadData.toMilliseconds()});
    try stdout.flush();

    const seed = if (config.seed) |s| s else blk: {
        var os_seed: u64 = undefined;
        init.io.random(std.mem.asBytes(&os_seed));
        break :blk os_seed;
    };

    const startTimeWireData = Io.Timestamp.now(init.io, .real);

    var topology: Topology = try .create(arena, sampled_topology);
    defer topology.delete(arena);

    const elapsedTimeWireData = startTimeWireData.untilNow(init.io, .real);

    var samp_top_var = sampled_topology;
    samp_top_var.delete(data_alloc);
    arena_json.deinit();

    try stdout.print("Time Elapsed wiring topology: {d} ms\n", .{elapsedTimeWireData.toMilliseconds()});
    try stdout.flush();

    // TODO: Switch this to IO
    const data_dir = std.fs.path.dirname(args.data) orelse ".";
    const dataset_name = if (args.output.len > 0) args.output else std.fs.path.basename(data_dir);

    var traces_base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const traces_base = try std.fmt.bufPrint(&traces_base_buf, "{s}", .{dataset_name});
    cwd.createDir(init.io, "traces", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // dw if the path already exists
        else => return err,
    };
    cwd.createDirPath(init.io, traces_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const run_dir = traces_base;

    var config_buff: [std.fs.max_path_bytes]u8 = undefined;
    const used_config_path = try std.fmt.bufPrint(&config_buff, "{s}/used_config.json", .{run_dir});
    const file_config = try Io.Dir.cwd().createFile(init.io, used_config_path, .{ .truncate = true });
    defer file_config.close(init.io);
    var config_buf2: [4096]u8 = undefined;
    var config_writer = file_config.writerStreaming(init.io, &config_buf2);
    const config_w = &config_writer.interface;
    try config_w.writeAll(content);
    try config_w.flush();

    var times_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const times_path = try std.fmt.bufPrint(&times_path_buf, "{s}/execution_times.ssv", .{run_dir});
    const times_file = try Io.Dir.cwd().createFile(init.io, times_path, .{ .truncate = true });
    defer times_file.close(init.io);

    var times_buf: [64]u8 = undefined;
    var times_writer = times_file.writerStreaming(init.io, &times_buf);
    const times_w = &times_writer.interface;
    try times_w.writeAll("batch run time_ms\n");
    try times_w.flush();

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const tio = threaded.io();

    var mutex_times: Io.Mutex = .init;

    var futures = try gpa.alloc(@TypeOf(try tio.concurrent(simulationBatch, undefined)), args.workers);
    defer gpa.free(futures);

    const runs_per_worker = args.runs / args.workers;
    const total_runs = args.runs;

    for (0..args.workers) |i| {
        const start_idx = i * runs_per_worker;
        const runs = if (i == args.workers - 1)
            total_runs - start_idx
        else
            runs_per_worker;

        const batch_args = .{
            &mutex_times,
            times_file,
            &topology,
            &config,
            seed,
            runs,
            start_idx,
            run_dir,
            i,
            args.skipjsonl,
        };
        futures[i] = try tio.concurrent(simulationBatch, batch_args);
        try stdout.print("Spawned batch {d} with {d} runs\n", .{ i, runs });
    }
    try stdout.flush();

    for (0..args.workers) |i| {
        try futures[i].await(tio);
    }
}

fn simulationBatch(
    mutex_times: *Io.Mutex,
    times_file: Io.File,
    topology: *const Topology,
    config: *const SimConfig,
    seed: u64,
    runs: usize,
    start_idx: usize,
    run_dir: []const u8,
    worker_id: usize,
    skipjsonl: bool,
) !void {
    var aa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    var general: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const deinit_status = general.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }
    const gpa = general.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &bufferr);
    const stderr = &stderr_writer.interface;

    var prng: Random.DefaultPrng = .init(seed);

    var state: SimState = try .create(io, arena, gpa, prng.random(), topology);
    defer state.delete(arena, gpa);

    if (worker_id == 0) {
        // Dump the configuration
        var b: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&b, "{s}/user_distributions.ssv", .{run_dir});
        try state.dumpUsers(io, path);
    }

    var times_buf: [256]u8 = undefined;
    var times_writer = times_file.writerStreaming(io, &times_buf);
    const times_w = &times_writer.interface;

    const action_name = "action_trace.bin";
    const session_name = "session_trace.bin";
    const create_name = "create_trace.bin";
    const propagation_name = "propagation_trace.bin";
    const swap_name = "swap_trace.bin";

    for (0..runs) |i| {
        const run_idx = start_idx + i;

        const run_seed = seed +% std.hash.Wyhash.hash(0, std.mem.asBytes(&run_idx));
        prng.seed(run_seed);

        const rng = prng.random();

        var elapsedTime: Io.Duration = undefined;

        // Comptime branch: the compiler eliminates the unused path entirely.
        // When trace_to_file=false, no files are created, no jsonl conversion.
        if (config.trace_to_file) {
            var action_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const action_bin = try std.fmt.bufPrint(&action_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, action_name });
            var session_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const session_bin = try std.fmt.bufPrint(&session_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, session_name });
            var create_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const create_bin = try std.fmt.bufPrint(&create_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, create_name });
            var prop_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const prop_bin = try std.fmt.bufPrint(&prop_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, propagation_name });
            var swap_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const swap_bin = try std.fmt.bufPrint(&swap_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, swap_name });

            var action_buffer: [64 * 1024]u8 = undefined;
            var session_buffer: [64 * 1024]u8 = undefined;
            var create_buffer: [64 * 1024]u8 = undefined;
            var propagation_buffer: [64 * 1024]u8 = undefined;
            var swap_buffer: [64 * 1024]u8 = undefined;

            const cwd = Io.Dir.cwd();
            const action_file = try cwd.createFile(io, action_bin, .{});
            defer action_file.close(io);
            var action_file_writer = action_file.writer(io, &action_buffer);
            const action_writer = &action_file_writer.interface;

            const session_file = try cwd.createFile(io, session_bin, .{});
            defer session_file.close(io);
            var session_file_writer = session_file.writer(io, &session_buffer);
            const session_writer = &session_file_writer.interface;

            const create_file = try cwd.createFile(io, create_bin, .{});
            defer create_file.close(io);
            var create_file_writer = create_file.writer(io, &create_buffer);
            const create_writer = &create_file_writer.interface;

            const prop_file = try cwd.createFile(io, prop_bin, .{});
            defer prop_file.close(io);
            var prop_file_writer = prop_file.writer(io, &propagation_buffer);
            const prop_writer = &prop_file_writer.interface;

            const swap_file = try cwd.createFile(io, swap_bin, .{});
            defer swap_file.close(io);
            var swap_file_writer = swap_file.writer(io, &swap_buffer);
            const swap_writer = &swap_file_writer.interface;

            const startTime = Io.Timestamp.now(io, .cpu_thread);
            const t = traces.TraceWriters{
                .action = action_writer,
                .session = session_writer,
                .create = create_writer,
                .propagate = prop_writer,
                .swaps = swap_writer,
            };
            const result = simulation.simulate(
                gpa,
                arena,
                rng,
                config,
                topology,
                &state,
                t,
            ) catch |err| {
                switch (err) {
                    error.OutOfMemoryQueue => try stderr.print("fatal - batch {d} run {d}: event queue ran out of memory\n", .{ worker_id, run_idx }),
                    error.OutOfMemoryTimeline => try stderr.print("fatal - batch {d} run {d}: user timeline ran out of memory\n", .{ worker_id, run_idx }),
                    error.OutOfMemorySMAList => try stderr.print("fatal - batch {d} run {d}: post list ran out of memory\n", .{ worker_id, run_idx }),
                    error.OutOfMemoryPagedBitSet => try stderr.print("fatal - batch {d} run {d}: bit matrix ran out of memory\n", .{ worker_id, run_idx }),
                    error.WriteFailed => try stderr.print("fatal - batch {d} run {d}: trace write to disk failed\n", .{ worker_id, run_idx }),
                }
                try stderr.flush();
                std.process.exit(1);
            };
            elapsedTime = startTime.untilNow(io, .cpu_thread);

            try stdout.print("{f}\n", .{result});
            try stdout.flush();

            // JSONL conversion
            var jsonl_buf: [std.fs.max_path_bytes]u8 = undefined;

            const action_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-action_trace.jsonl", .{ run_dir, run_idx });
            if (!skipjsonl) try traces.bytesToJsonl(io, traces.TraceAction, action_bin, action_jsonl);

            const session_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-session_trace.jsonl", .{ run_dir, run_idx });
            if (!skipjsonl) try traces.bytesToJsonl(io, traces.TraceSession, session_bin, session_jsonl);

            const create_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-create_trace.jsonl", .{ run_dir, run_idx });
            if (!skipjsonl) try traces.bytesToJsonl(io, traces.TraceCreate, create_bin, create_jsonl);

            const prop_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-propagate_trace.jsonl", .{ run_dir, run_idx });
            if (!skipjsonl) try traces.bytesToJsonl(io, traces.TracePropagation, prop_bin, prop_jsonl);

            const swap_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-swap_trace.jsonl", .{ run_dir, run_idx });
            if (!skipjsonl) try traces.bytesToJsonl(io, traces.TraceSwap, swap_bin, swap_jsonl);
        } else {
            // just run the simulation
            const startTime = Io.Timestamp.now(io, .cpu_thread);
            _ = try simulation.simulate(
                gpa,
                arena,
                rng,
                config,
                topology,
                &state,
                undefined,
            );
            elapsedTime = startTime.untilNow(io, .cpu_thread);
        }

        try mutex_times.lock(io);
        try times_w.print("{d} {d} {d}\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
        try times_w.flush();
        mutex_times.unlock(io);

        try stdout.print("[Batch {d} - {d}] - Execution time: {d} ms\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
        try stdout.flush();

        state.reset();
    }

    return;
}
