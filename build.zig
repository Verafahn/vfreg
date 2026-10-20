const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    const vfreg = b.addModule("vfreg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xml", .module = xml.module("xml") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "reg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vfreg", .module = vfreg },
            },
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const step = b.step("run", "");
    step.dependOn(&run.step);
    run.step.dependOn(b.getInstallStep());

    const @"test" = b.addTest(.{ .root_module = vfreg });
    const run_test = b.addRunArtifact(@"test");
    const test_step = b.step("test", "");
    test_step.dependOn(&run_test.step);
}
