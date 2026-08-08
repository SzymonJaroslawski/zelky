const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse (optimize != .Debug);

    const version_str = b.option([]const u8, "version", "Application version string") orelse "dev";

    const build_opt = b.addOptions();
    build_opt.addOption([]const u8, "version", version_str);

    const exe = b.addExecutable(.{
        .name = "zelky",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    exe.root_module.addOptions("build_options", build_opt);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
