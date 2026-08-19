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

    // Each OS gets its own audio-capture backend (see src/audio_backend.zig).
    switch (target.result.os.tag) {
        .linux => {
            exe.root_module.linkSystemLibrary("pulse", .{});
            exe.root_module.linkSystemLibrary("pulse-simple", .{});
        },
        .macos => {
            // CATapDescription (Core Audio Process Taps) has no plain-C
            // constructor, so audio_backend_macos.zig calls into a tiny
            // Objective-C shim for that one piece.
            exe.root_module.addIncludePath(b.path("src"));
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/macos_tap_shim.m"),
                .flags = &.{"-fobjc-arc"},
            });
            exe.root_module.linkFramework("CoreAudio", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
            exe.root_module.linkFramework("Foundation", .{});
        },
        else => {},
    }

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run PragmaticAudio");
    run_step.dependOn(&run_cmd.step);

    b.installArtifact(exe);
}
