// macOS audio-capture backend -- not implemented yet.
//
// A real implementation would capture desktop audio via Core Audio: open
// the default output device's associated loopback/tap (there is no built-in
// monitor source like PulseAudio's -- either an aggregate device with a
// tap on the output, or Core Audio's process/hardware tap APIs on newer
// macOS, or a virtual loopback driver such as BlackHole as a fallback),
// pull samples on a dedicated thread, and invoke `on_chunk` per chunk. See
// audio_backend.zig for the exact contract every backend must implement.
const std = @import("std");

pub const Frame = [2]f32;
pub const ChunkFn = *const fn (ctx: ?*anyopaque, frames: []const Frame) void;

pub const DeviceInfo = struct {
    name: [:0]const u8,
    description: [:0]const u8,

    pub fn free(self: DeviceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub fn listSources(allocator: std.mem.Allocator) ![]DeviceInfo {
    _ = allocator;
    return &.{};
}

pub const Capture = struct {
    pub fn init(io: std.Io, sample_rate: u32, on_chunk: ?ChunkFn, on_chunk_ctx: ?*anyopaque, device: ?[:0]const u8) !*Capture {
        _ = .{ io, sample_rate, on_chunk, on_chunk_ctx, device };
        return error.NotImplemented;
    }

    pub fn deinit(self: *Capture) void {
        _ = self;
    }
};
