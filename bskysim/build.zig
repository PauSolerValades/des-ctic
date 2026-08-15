const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_pool = b.option(bool, "use_pool", "Use timeline pool allocator") orelse false;

    const opts = b.addOptions();
    opts.addOption(bool, "use_pool", use_pool);

    const exe = b.addExecutable(.{
        .name = b.fmt("bskysim", .{}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addOptions("build_options", opts);

    const eazy_args_dep = b.dependency("eazy_args", .{
        .target = target,
        .optimize = optimize,
    });
    const eazy_args_mod = eazy_args_dep.module("eazy_args");

    const ds_dep = b.dependency("ds_bskysim", .{ // this is the repo name
        .target = target,
        .optimize = optimize,
    });
    const ds_mod = ds_dep.module("ds"); // this is the name on the build.zig on that repo

    const distributions_dep = b.dependency("distributions", .{
        .target = target,
        .optimize = optimize,
    });
    const distributions_mod = distributions_dep.module("distributions");

    const tabular_dep = b.dependency("tabular", .{
        .target = target,
        .optimize = optimize,
    });
    const tabular_mod = tabular_dep.module("tabular");

    // link the dependencies in here
    exe.root_module.addImport("eazy_args", eazy_args_mod);
    exe.root_module.addImport("ds", ds_mod);
    exe.root_module.addImport("distributions", distributions_mod);
    exe.root_module.addImport("tabular", tabular_mod);

    b.installArtifact(exe); // creates the exe in the folder

    const run_cmd = b.addRunArtifact(exe);

    // Install it as the module
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
