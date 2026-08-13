const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("distributions", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // const dtest_mod = b.addModule("dtest", .{
    //     .root_source_file = b.path("test/kolmogorov-smirnov.zig"),
    //     .target = target,
    // });

    const dtest_exe = b.addExecutable(.{
        .name = "dtest",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/kolmogorov-smirnov.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "distributions", .module = mod },
        } }),
    });

    const gof_step = b.step("gof", "Run goodness of fit tests");
    const gof_cmd = b.addRunArtifact(dtest_exe);
    gof_step.dependOn(&gof_cmd.step);

    const examples_step = b.step("examples", "Compile the examples in \"examples\" folder");

    // TODO: just make this return a list of filenames
    const examples = [_][]const u8{
        "intro",
        "continous_distribution",
        "discrete_distribution",
        "union",
        "union_discrete",
    };

    // compile the examples
    for (examples) |example| {
        const source_path = b.fmt("examples/{s}.zig", .{example});

        const example_exe = b.addExecutable(.{
            .name = example,
            .root_module = b.createModule(.{
                .root_source_file = b.path(source_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "distributions", .module = mod },
                },
            }),
        });

        //b.installArtifact(example_exe);
        //const example_cmd = b.addRunArtifact(example_exe);
        const example_cmd = b.addInstallArtifact(example_exe, .{
            .dest_dir = .{ .override = .{ .custom = "examples" } },
        });
        examples_step.dependOn(&example_cmd.step);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Release step: runs tests + gof.
    const release_step = b.step("release", "Run tests and gof");
    release_step.dependOn(test_step);
    release_step.dependOn(gof_step);
}
