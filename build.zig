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
    buckets: ?u32,
    bucket_file: ?[]const u8,
    output_file: ?[]const u8,
    traces_dir: []const u8,
};

const JobConfig = struct {
    simulation: ?*SimulationConfig,
    cascade: ?*CascadesConfig,
};

const Recompile = enum { simulation, cascades, datasets, pipeline, all };

pub fn build(b: *Build) void {
    var threaded: Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &bufferr);
    const stderr = &stderr_writer.interface;

    const config_path = b.option([]const u8, "config", "Path to the configuration for this Job") orelse
        @panic("A configuration file must be provided");
    const recompile = b.option(Recompile, "compile", "Which parts of the pipeline to rebuild and move to the bin folder");

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

    var cascade_list: std.ArrayList([]const u8) = .empty;
    defer cascade_list.deinit(b.allocator);

    var cascade_step: ?*Build.Step = null;
    if (config.cascade) |cascade_config| {
        var b_buf: [16]u8 = undefined;
        cascadeArguments(b.allocator, &cascade_list, cascade_config, &b_buf) catch |err| {
            switch (err) {
                error.NoSpaceLeft => @panic("buffer too small for -b argument"),
                error.OutOfMemory => @panic("OOM building cascade arguments"),
            }
        };
        const run_cascades = b.addSystemCommand(cascade_list.items);
        run_cascades.step.dependOn(&run_sim.step);
        cascade_step = &run_cascades.step;
    }

    if (recompile) |c| {
        switch (c) {
            .simulation => {
                const compile_sim = b.addSystemCommand(&[_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast", "-p", "../" });
                compile_sim.setCwd(.{ .cwd_relative = "bskysim" });
                run_sim.step.dependOn(&compile_sim.step);
            },
            .cascades => {
                const compile_cas = b.addSystemCommand(&[_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast", "-p", "../" });
                compile_cas.setCwd(.{ .cwd_relative = "construct-cascades" });
                // Always attach: cascade step if present, otherwise simulation
                (cascade_step orelse &run_sim.step).dependOn(&compile_cas.step);
            },
            else => @panic("Not supported rn"),
        }
    }

    const all_step = b.step("all", "Run simulation and cascade construction");
    all_step.dependOn(&run_sim.step);
    if (cascade_step) |cs| all_step.dependOn(cs);
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

fn cascadeArguments(
    gpa: std.mem.Allocator,
    arg_list: *std.ArrayList([]const u8),
    config: *const CascadesConfig,
    b_buf: []u8,
) !void {
    try arg_list.append(gpa, "./bin/construct-cascade");

    if (config.buckets) |b| {
        try arg_list.append(gpa, try std.fmt.bufPrint(b_buf, "-b{}", .{b}));
    }
    if (config.bucket_file) |bf| {
        try arg_list.append(gpa, "-p");
        try arg_list.append(gpa, bf);
    }
    if (config.output_file) |out| {
        try arg_list.append(gpa, "-o");
        try arg_list.append(gpa, out);
    }

    try arg_list.append(gpa, config.traces_dir);
}
