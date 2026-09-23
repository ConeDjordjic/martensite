const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("martensite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this");
    const test_step = b.step("test", "Run the tests");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

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

    const api = b.addExecutable(.{
        .name = "api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "martensite", .module = mod }},
        }),
    });
    b.installArtifact(api);

    // Only built here, never run, because it needs the network and a CA
    // bundle.
    const tls_client = b.addExecutable(.{
        .name = "tls-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tls_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "martensite", .module = mod }},
        }),
    });
    b.installArtifact(tls_client);

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
