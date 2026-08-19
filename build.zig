const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    const exe = b.addExecutable(.{ .name = "PragmaticAudio", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .optimize = optimize, .target = target }) });

    exe.root_module.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    exe.root_module.link_libc = true;

    // Only the Linux backend (src/audio_backend_linux.zig) needs PulseAudio;
    // macOS/Windows builds compile a stub backend instead (see
    // src/audio_backend.zig) and don't need anything linked for it yet.
    switch (target.result.os.tag) {
        .linux => {
            exe.root_module.linkSystemLibrary("pulse", .{});
            exe.root_module.linkSystemLibrary("pulse-simple", .{});
        },
        else => {},
    }

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run PragmaticAudio");
    run_step.dependOn(&run_cmd.step);

    b.installArtifact(exe);
}
