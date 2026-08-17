const std = @import("std");
const Random = std.Random;
const Io = std.Io;

const argz = @import("eazy_args");

const SimConfig = @import("SimConfig.zig");
const simulation = @import("simulation.zig");
const loader = @import("load-topology.zig");
const entities = @import("entities.zig");
const topo = @import("Topology.zig");
const SimState = @import("SimState.zig");
const traces = @import("traces.zig");

const Topology = topo;
// const SimState = topo.SimState; // UNCOMMENT LATER

const Arg = argz.Argument;
const Opt = argz.Option;
const Flag = argz.Flag;

const ParseErrors = argz.ParseErrors;

const def = .{
    .name = "ctic-adqb",
    .description = "Continuous-Time Independent Cascade, Activity Driven Queue Based Simulation of a Bluesky-like network.",
    .required = .{
        Arg([]const u8, "datafile", "Data file containing the network definition"),
        Arg([]const u8, "configfile", "Input parameters"),
    },
    .options = .{
        Opt(?[]const u8, "outputdir", "o", null, "Dataset name for trace folder"),
        Opt(u32, "runs", "n", 1, "Runs to execute the simulation"),
        Opt(u32, "workers", "w", 1, "Units of parallelism"),
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

    var iter = init.minimal.args.iterate();
    const args = parseAndValidateCmdArgs(&iter, stdout, stderr) catch std.process.exit(1);

    var arena_json: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const data_alloc = arena_json.allocator();

    const config: SimConfig = SimConfig.create(init.io, gpa, args.configfile, stderr) catch |err| {
        switch (err) {
            error.OutOfMemory => try stderr.writeAll("Out of memory while parsing config.\n"),
            error.WriteFailed => {}, // stderr already dead, nothing to do, just crash
            error.InvalidCharacter => try stderr.writeAll("Invalid number in config file.\n"),
            // JsonScannerError: JSON structure is malformed
            error.UnexpectedToken, error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun => try stderr.writeAll("Invalid JSON config file.\n"),
            // ParseError: diagnostic already printed by the parser
            error.UnknownDistribution, error.UnknownParameter, error.MissingField, error.InvalidInterval, error.InvalidField => {},
            // std.json.ParseError(Scanner): typed parsing of the users array failed
            error.Overflow, error.InvalidNumber, error.InvalidEnumTag, error.DuplicateField, error.UnknownField, error.LengthMismatch, error.ValueTooLong => try stderr.writeAll("Problem while parsing user configuration.\n"),
            error.FileNotFound => try stderr.print("Config file {s} is not found.\n", .{args.configfile}),
            error.IsDir => try stderr.print("{s} is a directory.\n", .{args.configfile}),
            else => try stderr.print("Unexpected error: {}", .{err}),
        }
        try stderr.flush();
        std.process.exit(1);
    };
    defer config.delete(gpa);
    try stderr.flush(); // a warning in the distribution parsing can actually happen

    config.isValid(init.io, stderr) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NegativeHorizon => "horizon must be > 0\n",
            error.NegativeDuration => "duration must be > 0\n",
            error.NegativeWarmup => "warmup_time must be > 0\n",
            error.DurationBiggerThenHorizon => "warmup_time + duration must not exceed horizon\n",
            error.RepeatedUserPair => "users: repeated (session_duration, inter_session_time) pair\n",
            error.ProbabilityNotOne => "users: probabilities must sum to 1\n",
            error.EcdfPostFileError => "users: ecdf_post_creation file missing (see detail above)\n",
            error.EcdfOffsetFileError => "users: ecdf_offset file missing (see detail above)\n",
            error.SampleParamsFileError => "users: ecdf_parameters file missing (see detail above)\n",
            error.WriteFailed => "", // stderr already dead
            error.OutOfMemory => "out of memory while validating config\n",
        };
        try stderr.print("{s}", .{msg});
        try stderr.flush();
        std.process.exit(1);
    };

    const startTimeLoadData = Io.Timestamp.now(init.io, .real);
    const sampled_topology = try loader.BinaryGraph.create(init.io, data_alloc, args.datafile);
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

    try stdout.print("Time Elapsed Wiring Topology: {d} ms\n", .{elapsedTimeWireData.toMilliseconds()});
    try stdout.flush();

    var output_buff: [std.fs.max_path_bytes]u8 = undefined;
    const output_job_dir = if (args.outputdir) |od| od else blk: {
        break :blk try std.fmt.bufPrint(&output_buff, "./traces/{d}", .{Io.Timestamp.now(init.io, .real).toMilliseconds()});
    };
    Io.Dir.cwd().createDirPath(
        init.io,
        output_job_dir,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try createUsedConfig(init.io, output_job_dir, args.configfile);
    const times_file = try createExecutionTimes(init.io, output_job_dir);
    defer times_file.close(init.io);

    var prng: Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    const startTimeUsers = Io.Timestamp.now(init.io, .real);
    var state: SimState = try .create(init.io, arena, init.gpa, rng, &topology, config.users);
    defer state.delete(arena, init.gpa);
    const elapsedTimeUsers = startTimeUsers.untilNow(init.io, .real);

    try stdout.print("Time Elapsed Assigning Users: {d} ms\n", .{elapsedTimeUsers.toMilliseconds()});
    try stdout.flush();

    try launchWorkers(
        gpa,
        times_file,
        &topology,
        &state,
        &config,
        seed,
        output_job_dir,
        args.workers,
        args.runs,
        args.skipjsonl,
        stdout,
    );
}

fn launchWorkers(
    gpa: std.mem.Allocator,
    times_file: Io.File,
    topology: *const Topology,
    state: *const SimState,
    config: *const SimConfig,
    seed: u64,
    run_dir: []const u8,
    workers: u32,
    total_runs: u32,
    skipjsonl: bool,
    stdout: *Io.Writer,
) !void {
    var mutex_times: Io.Mutex = .init;

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const tio = threaded.io();

    var futures = try gpa.alloc(@TypeOf(try tio.concurrent(simulationBatch, undefined)), workers);
    defer gpa.free(futures);

    const runs_per_worker = total_runs / workers;

    for (0..workers) |i| {
        const start_idx = i * runs_per_worker;
        const runs = if (i == workers - 1)
            total_runs - start_idx
        else
            runs_per_worker;

        const batch_args = .{
            &mutex_times,
            times_file,
            topology,
            state,
            config,
            seed,
            runs,
            start_idx,
            run_dir,
            i,
            skipjsonl,
        };
        futures[i] = try tio.concurrent(simulationBatch, batch_args);
        try stdout.print("Spawned batch {d} with {d} runs\n", .{ i, runs });
    }
    try stdout.flush();

    for (0..workers) |i| {
        try futures[i].await(tio);
    }
}

fn simulationBatch(
    mutex_times: *Io.Mutex,
    times_file: Io.File,
    topology: *const Topology,
    state_template: *const SimState,
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

    // per-worker copy of the state; reset() between runs, delete() at the end
    var state: SimState = try state_template.clone(arena, gpa);
    defer state.delete(arena, gpa);

    var prng: Random.DefaultPrng = .init(seed);

    if (worker_id == 0) {
        // Dump the configuration
        var b: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&b, "{s}/user_distributions.tsv", .{run_dir});
        try state.dumpUsers(io, path);
    }

    var times_buf: [256]u8 = undefined;
    var times_writer = times_file.writerStreaming(io, &times_buf);
    const times_w = &times_writer.interface;

    for (0..runs) |i| {
        const run_idx = start_idx + i;

        const run_seed = seed +% std.hash.Wyhash.hash(0, std.mem.asBytes(&run_idx));
        prng.seed(run_seed);

        const rng = prng.random();

        var elapsedTime: Io.Duration = undefined;
        if (config.trace_to_file) {
            elapsedTime = try runTracedSimulation(
                io,
                gpa,
                arena,
                rng,
                config,
                topology,
                &state,
                run_dir,
                run_idx,
                worker_id,
                skipjsonl,
                stdout,
                stderr,
            );
        } else {
            const startTime = Io.Timestamp.now(io, .cpu_thread);
            _ = try simulation.simulate(gpa, arena, rng, config, topology, &state, undefined);
            elapsedTime = startTime.untilNow(io, .cpu_thread);
        }

        try mutex_times.lock(io);
        try times_w.print("{d} {d} {d}\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
        try times_w.flush();
        mutex_times.unlock(io);

        try stdout.print("[Batch {d} - {d}] - Execution time: {d} ms", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
        if (state.poolFallbacks() > 0) {
            try stdout.print(" | pool-fallbacks: {d}", .{state.poolFallbacks()});
        }
        try stdout.print("\n", .{});
        try stdout.flush();

        state.reset();
    }

    return;
}

fn runTracedSimulation(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    rng: Random,
    config: *const SimConfig,
    topology: *const Topology,
    state: *SimState,
    run_dir: []const u8,
    run_idx: usize,
    worker_id: usize,
    skipjsonl: bool,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !Io.Duration {
    const action_name = "action_trace.bin";
    const session_name = "session_trace.bin";
    const create_name = "create_trace.bin";
    const propagation_name = "propagation_trace.bin";
    const swap_name = "swap_trace.bin";

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
        state,
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
    const elapsed = startTime.untilNow(io, .cpu_thread);

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

    return elapsed;
}

pub fn parseAndValidateCmdArgs(iter: *std.process.Args.Iterator, stdout: *Io.Writer, stderr: *Io.Writer) error{WriteFailed}!argz.Reify(def) {
    const args = argz.parseArgsPosix(def, iter, stdout, stderr) catch |err| {
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

    if (std.mem.eql(u8, std.fs.path.extension(args.configfile), "json")) {
        try stderr.print("The provided config file ({s}) does not have a 'json' extension\n", .{args.configfile});
        try stderr.flush();
        std.process.exit(1);
    }

    if (!std.mem.eql(u8, std.fs.path.extension(args.datafile), ".bin")) {
        try stderr.writeAll("warning - the provided data file does not have a .bin extension. Are you sure it's a valid topology?");
        try stderr.flush();
    }

    return args;
}

// a generic copy file function lol
fn copyFile(io: Io, src_path: []const u8, dst_path: []const u8) !void {
    const src = try Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);
    const dst = try Io.Dir.cwd().createFile(io, dst_path, .{ .truncate = true });
    defer dst.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = src.reader(io, &rbuf);
    var writer = dst.writer(io, &wbuf);

    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
}

fn createUsedConfig(io: Io, dir: []const u8, src_config_path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dst = try std.fmt.bufPrint(&buf, "{s}/used_config.json", .{dir});
    try copyFile(io, src_config_path, dst);
}

fn createExecutionTimes(io: Io, dir: []const u8) !Io.File {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/execution_times.ssv", .{dir});
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    var wbuf: [64]u8 = undefined;
    var writer = file.writerStreaming(io, &wbuf);
    try writer.interface.writeAll("batch run time_ms\n");
    try writer.interface.flush();
    return file;
}
