const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("martensite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the tests").dependOn(&run_tests.step);

    const ws = b.addExecutable(.{
        .name = "websocket",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/websocket.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "martensite", .module = mod }},
        }),
    });
    b.installArtifact(ws);

    const example = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "martensite", .module = mod }},
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    b.step("run", "Run the hello example").dependOn(&run_example.step);
}
