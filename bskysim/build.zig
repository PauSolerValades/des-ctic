const std = @import("std");

const jemalloc_version = "5.3.1-144-ge36a0fa5";

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

    // std.heap.c_allocator (and therefore std.process.Init.gpa) needs libc.
    exe.root_module.link_libc = true;
    // Zig 0.16's linker can't handle the .sframe relocations in newer glibc
    // startup objects (GCC 16 / binutils 2.47); force gc-sections like release.
    exe.link_gc_sections = true;

    // jemalloc is a prebuilt static lib (see deps/jemalloc/README.md). The
    // filename encodes the version, so this check also enforces it.
    const jemalloc_rel = b.fmt("deps/jemalloc/libjemalloc-{s}.a", .{jemalloc_version});
    const jemalloc_found = blk: {
        std.Io.Dir.access(b.build_root.handle, b.graph.io, jemalloc_rel, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (jemalloc_found) {
        exe.root_module.addObjectFile(b.path(jemalloc_rel));
    } else {
        b.getInstallStep().dependOn(&b.addFail(b.fmt(
            "jemalloc not found: expected {s}\n" ++
                "See deps/jemalloc/README.md - build it from a jemalloc checkout and\n" ++
                "drop the archive there (the filename encodes the version).",
            .{jemalloc_rel},
        )).step);
    }

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

    const set_dep = b.dependency("ziglangSet", .{
        .target = target,
        .optimize = optimize,
    });
    const set_mod = set_dep.module("ziglangSet");

    // link the dependencies in here
    exe.root_module.addImport("eazy_args", eazy_args_mod);
    exe.root_module.addImport("ds", ds_mod);
    exe.root_module.addImport("distributions", distributions_mod);
    exe.root_module.addImport("tabular", tabular_mod);
    exe.root_module.addImport("set", set_mod);

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
