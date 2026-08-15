const std = @import("std");
const Build = std.Build;

const Io = std.Io;

const SimulationConfig = struct {
    workers: ?u32,
    runs: ?u32,
    output_dir: ?[]const u8,
    config_file: []const u8,
    data_file: []const u8,
};

const CascadesConfig = struct {
    buckets: ?u32,
    bucket_file: ?[]const u8,
    output_file: ?[]const u8,
    traces_dir: []const u8,
};

const DatasetConfig = struct {
    output_dir: ?[]const u8,
    cascades_ssv: []const u8,
    likes_ssv: []const u8,
    traces_dir: []const u8,
    dataset: []const u8,
};

const JobConfig = struct {
    simulation: ?*SimulationConfig,
    cascade: ?*CascadesConfig,
    dataset: ?*DatasetConfig,
};

const Recompile = enum { simulation, cascades, datasets, pipeline, all };

pub fn build(b: *Build) void {
    var threaded: Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &bufferr);
    const stderr = &stderr_writer.interface;

    const config_path = b.option([]const u8, "config", "Path to the configuration for this Job") orelse {
        b.default_step = b.step("noop", "no-op: pass -Dconfig=... to run anything");
        return;
    };
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

    const sim_step = buildSimulation(b, &config);
    const cascade_step = buildCascades(b, &config, sim_step);
    const dataset_step = buildDatasets(b, &config, cascade_step orelse sim_step);

    if (recompile) |c| {
        switch (c) {
            .simulation => sim_step.dependOn(compileSimulation(b)),
            .cascades => (cascade_step orelse sim_step).dependOn(compileCascades(b)),
            .datasets => {
                const dep: *Build.Step = dataset_step orelse cascade_step orelse sim_step;
                dep.dependOn(compileDatasets(b));
            },
            .pipeline => {
                (cascade_step orelse sim_step).dependOn(compileCascades(b));
                const dep: *Build.Step = dataset_step orelse cascade_step orelse sim_step;
                dep.dependOn(compileDatasets(b));
            },
            .all => {
                sim_step.dependOn(compileSimulation(b));
                (cascade_step orelse sim_step).dependOn(compileCascades(b));
                const dep: *Build.Step = dataset_step orelse cascade_step orelse sim_step;
                dep.dependOn(compileDatasets(b));
            },
        }
    }

    const all_step = b.step("all", "Run simulation, cascade construction, and dataset creation");
    all_step.dependOn(sim_step);
    if (cascade_step) |cs| all_step.dependOn(cs);
    if (dataset_step) |ds| all_step.dependOn(ds);
}

fn buildSimulation(b: *Build, config: *const JobConfig) *Build.Step {
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(b.allocator);

    const sim_config = config.simulation orelse @panic("Simulation is null on the json wtf");

    var w_buf: [16]u8 = undefined;
    var n_buf: [16]u8 = undefined;
    simulationArguments(b.allocator, &arg_list, sim_config, &w_buf, &n_buf) catch |err| {
        switch (err) {
            error.NoSpaceLeft => @panic("buffer too small for -w/-n argument"),
            error.OutOfMemory => @panic("OOM building simulation arguments"),
        }
    };
    const run_sim = b.addSystemCommand(arg_list.items);
    return &run_sim.step;
}

fn buildCascades(b: *Build, config: *const JobConfig, dep: *Build.Step) ?*Build.Step {
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(b.allocator);

    const cascade_config = config.cascade orelse return null;

    var b_buf: [16]u8 = undefined;
    cascadeArguments(b.allocator, &arg_list, cascade_config, &b_buf) catch |err| {
        switch (err) {
            error.NoSpaceLeft => @panic("buffer too small for -b argument"),
            error.OutOfMemory => @panic("OOM building cascade arguments"),
        }
    };
    const run_cascades = b.addSystemCommand(arg_list.items);
    run_cascades.step.dependOn(dep);
    return &run_cascades.step;
}

fn buildDatasets(b: *Build, config: *const JobConfig, dep: *Build.Step) ?*Build.Step {
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(b.allocator);

    const dataset_config = config.dataset orelse return null;

    datasetsArguments(b.allocator, &arg_list, dataset_config) catch |err| {
        switch (err) {
            error.OutOfMemory => @panic("OOM building dataset arguments"),
        }
    };
    const run_datasets = b.addSystemCommand(arg_list.items);
    run_datasets.step.dependOn(dep);
    return &run_datasets.step;
}

fn compileSimulation(b: *Build) *Build.Step {
    const cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast", "-p", "../" });
    cmd.setCwd(.{ .cwd_relative = "bskysim" });
    return &cmd.step;
}

fn compileCascades(b: *Build) *Build.Step {
    const cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast", "-p", "../" });
    cmd.setCwd(.{ .cwd_relative = "construct-cascades" });
    return &cmd.step;
}

fn compileDatasets(b: *Build) *Build.Step {
    const cmd = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", "../bin/dataset-creation", "." });
    cmd.setCwd(.{ .cwd_relative = "dataset-creation" });
    return &cmd.step;
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

fn datasetsArguments(
    gpa: std.mem.Allocator,
    arg_list: *std.ArrayList([]const u8),
    config: *const DatasetConfig,
) !void {
    try arg_list.append(gpa, "./bin/dataset-creation");

    if (config.output_dir) |out| {
        try arg_list.append(gpa, "-output");
        try arg_list.append(gpa, out);
    }

    try arg_list.append(gpa, config.cascades_ssv);
    try arg_list.append(gpa, config.likes_ssv);
    try arg_list.append(gpa, config.traces_dir);
    try arg_list.append(gpa, config.dataset);
}
