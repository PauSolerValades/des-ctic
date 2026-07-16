const std = @import("std");
const Build = std.Build;

const Io = std.Io;

const SimulationConfig = struct {
    workers: ?u32,
    runs: ?u32,
    output_dir: ?[]const u8,
    params_dir: ?[]const u8,
    config_file: []const u8,
    data_file: []const u8,
};

const CascadesConfig = struct {
    tmp_dir: ?[]const u8,
    output_dir: ?[]const u8,
    execution_dir: []const u8,
};

const JobConfig = struct {
    simulation: ?*SimulationConfig,
    cascade: ?*CascadesConfig,
};

pub fn build(b: *Build) void {
    var threaded: Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &bufferr);
    const stderr = &stderr_writer.interface;

    const config_path = b.option([]const u8, "config", "Path to the configuration for this Job") orelse
        @panic("A configuration file must be provided");
    // const rebuild = b.option(bool, "rebuild", "Should we rebuild the simulation?");

    const config_contents = Io.Dir.cwd().readFileAlloc(io, config_path, b.allocator, .unlimited) catch |err| {
        switch (err) {
            error.FileNotFound => stderr.print("Config file {s} is not found.\n", .{config_path}) catch @panic("stderr not created"),
            error.IsDir => stderr.print("{s} is a directory.\n", .{config_path}) catch @panic("stderr not created"),
            else => stderr.print("Unexpected error: {}", .{err}) catch @panic("stderr not created"),
        }
        @panic("Error opening the Job configuration file");
    };

    const parsed = std.json.parseFromSlice(JobConfig, b.allocator, config_contents, .{}) catch |err| {
        std.debug.print("Failed to parse JSON config: {}\n", .{err});
        return;
    };
    defer parsed.deinit();
    const config = parsed.value;

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(b.allocator);

    const simulation_config: *SimulationConfig = config.simulation orelse @panic("Simulation is null on the json wtf");

    var w_buf: [16]u8 = undefined;
    var n_buf: [16]u8 = undefined;
    simulationArguments(b.allocator, &arg_list, simulation_config, &w_buf, &n_buf) catch |err| {
        switch (err) {
            error.NoSpaceLeft => @panic("buffer too small for -w/-n argument"),
            error.OutOfMemory => @panic("OOM building simulation arguments"),
        }
    };
    const run_sim = b.addSystemCommand(arg_list.items);

    // if (rebuild) {
    //     const rebuild_sim = b.addSystemCommand(&.{ "zig", "build", "-Doptimize=ReleaseFast", });
    // }
    const all_step = b.step("all", "Run the simulation");
    all_step.dependOn(&run_sim.step);
}

fn simulationArguments(
    gpa: std.mem.Allocator,
    arg_list: *std.ArrayList([]const u8),
    config: *const SimulationConfig,
    w_buf: []u8,
    n_buf: []u8,
) !void {
    try arg_list.append(gpa, "./bin/bskysim");

    if (config.workers) |w| {
        try arg_list.append(gpa, try std.fmt.bufPrint(w_buf, "-w{}", .{w}));
    }
    if (config.runs) |n| {
        try arg_list.append(gpa, try std.fmt.bufPrint(n_buf, "-n{}", .{n}));
    }

    if (config.params_dir) |params_dir| {
        try arg_list.append(gpa, "--paramsdir");
        try arg_list.append(gpa, params_dir);
    }

    if (config.output_dir) |output_dir| {
        try arg_list.append(gpa, "--outputdir");
        try arg_list.append(gpa, output_dir);
    }

    try arg_list.append(gpa, config.data_file);
    try arg_list.append(gpa, config.config_file);
}
