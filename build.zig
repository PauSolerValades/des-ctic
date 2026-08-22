const std = @import("std");
const Build = std.Build;

const SimulationConfig = struct {
    workers: ?u32,
    runs: ?u32,
    output_dir: ?[]const u8,
    config_file: []const u8,
    data_file: []const u8,
    userparams_file: []const u8,
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

pub fn build(b: *Build) !void {
    // declare all the steps
    const sim_step = b.step("sim", "Run the simulation");
    const cascades_step = b.step("cascades", "Run cascade construction");
    const datasets_step = b.step("datasets", "Run dataset creation");
    const pipeline_step = b.step("pipeline", "Run cascades + datasets from existing traces");
    const all_step = b.step("all", "Run simulation, cascades, and datasets");
    const steps: []const *Build.Step = &.{ sim_step, cascades_step, datasets_step, pipeline_step, all_step };

    // Make all the binaries compile if necessary
    const sim_exe = b.dependency("bskysim", .{ .optimize = .ReleaseFast }).artifact("bskysim");
    const cascades_exe = b.dependency("cascade", .{ .optimize = .ReleaseFast }).artifact("construct-cascade");
    b.installArtifact(sim_exe);
    b.installArtifact(cascades_exe);

    // The go binary must be compiled manually
    const go_build = b.addSystemCommand(&.{ "go", "build", "-o", "../bin/dataset-creation", "." });
    go_build.setCwd(.{ .cwd_relative = "dataset" });
    b.getInstallStep().dependOn(&go_build.step);

    const config_path = b.option([]const u8, "config", "Path to the configuration for this job") orelse {
        failAll(b, "pass -Dconfig=<file>.json to run anything", steps);
        return;
    };

    const config_contents = std.Io.Dir.cwd().readFileAlloc(b.graph.io, config_path, b.allocator, .unlimited) catch {
        failAll(b, b.fmt("cannot read config file: {s}", .{config_path}), steps);
        return;
    };

    const parsed = std.json.parseFromSlice(JobConfig, b.allocator, config_contents, .{}) catch |err| {
        failAll(b, b.fmt("invalid JSON in config file {s}: {}", .{ config_path, err }), steps);
        return;
    };
    const config = parsed.value;

    const sim_argv = if (config.simulation) |c| try simulationArgs(b, c) else null;
    const cascades_argv = if (config.cascade) |c| try cascadesArgs(b, c) else null;
    const datasets_argv = if (config.dataset) |c| try datasetsArgs(b, c) else null;

    sim_step.dependOn(zigStage(b, sim_exe, sim_argv, "simulation"));
    cascades_step.dependOn(zigStage(b, cascades_exe, cascades_argv, "cascade"));
    datasets_step.dependOn(goStage(b, datasets_argv, &go_build.step, "dataset"));

    // Pipeline: cascades feeds datasets, so they must be ordered.
    const p_cascades = zigStage(b, cascades_exe, cascades_argv, "cascade");
    const p_datasets = goStage(b, datasets_argv, &go_build.step, "dataset");
    p_datasets.dependOn(p_cascades);
    pipeline_step.dependOn(p_datasets);

    // All: full chain, ordered — sections absent from the config are skipped.
    const a_sim = zigStage(b, sim_exe, sim_argv, "simulation");
    var a_cascades = a_sim;
    if (cascades_argv) |_| {
        a_cascades = zigStage(b, cascades_exe, cascades_argv, "cascade");
        a_cascades.dependOn(a_sim);
    }
    var a_datasets = a_cascades;
    if (datasets_argv) |_| {
        a_datasets = goStage(b, datasets_argv, &go_build.step, "dataset");
        a_datasets.dependOn(a_cascades);
    }
    all_step.dependOn(a_datasets);
}

/// Check if the proper json config is null. if it is we add fail gracefuly, if not executed
fn zigStage(b: *Build, exe: *Build.Step.Compile, argv: ?[]const []const u8, section: []const u8) *Build.Step {
    const a = argv orelse return &b.addFail(b.fmt("config is missing the '{s}' section", .{section})).step;
    const cmd = b.addRunArtifact(exe);
    cmd.addArgs(a);
    cmd.has_side_effects = true;
    return &cmd.step;
}

/// Same, for the go binary; zig can't see inside `go build`, so the edge is manual.
fn goStage(b: *Build, argv: ?[]const []const u8, go_build: *Build.Step, section: []const u8) *Build.Step {
    const a = argv orelse return &b.addFail(b.fmt("config is missing the '{s}' section", .{section})).step;
    const cmd = b.addSystemCommand(a);
    cmd.has_side_effects = true;
    cmd.step.dependOn(go_build);
    return &cmd.step;
}

fn failAll(b: *Build, msg: []const u8, steps: []const *Build.Step) void {
    const fail = b.addFail(msg);
    for (steps) |s| s.dependOn(&fail.step);
}

// Create arguments functions

fn simulationArgs(b: *Build, c: *const SimulationConfig) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (c.workers) |w| try args.append(b.allocator, b.fmt("-w{d}", .{w}));
    if (c.runs) |n| try args.append(b.allocator, b.fmt("-n{d}", .{n}));
    if (c.output_dir) |o| try args.appendSlice(b.allocator, &.{ "--outputdir", o });
    try args.appendSlice(b.allocator, &.{ c.data_file, c.config_file, c.userparams_file });
    return args.items;
}

fn cascadesArgs(b: *Build, c: *const CascadesConfig) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (c.buckets) |n| try args.append(b.allocator, b.fmt("-b{d}", .{n}));
    if (c.bucket_file) |f| try args.appendSlice(b.allocator, &.{ "-p", f });
    if (c.output_file) |o| try args.appendSlice(b.allocator, &.{ "-o", o });
    try args.append(b.allocator, c.traces_dir);
    return args.items;
}

fn datasetsArgs(b: *Build, c: *const DatasetConfig) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(b.allocator, "./bin/dataset-creation");
    if (c.output_dir) |o| try args.appendSlice(b.allocator, &.{ "-output", o });
    try args.appendSlice(b.allocator, &.{ c.cascades_ssv, c.likes_ssv, c.traces_dir, c.dataset });
    return args.items;
}
