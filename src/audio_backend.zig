// Selects the platform audio-capture backend at compile time. Every backend
// (audio_backend_<platform>.zig) must export exactly this surface:
//
//   pub const Frame = [2]f32;                 -- one interleaved L/R sample
//   pub const ChunkFn = *const fn (ctx: ?*anyopaque, frames: []const Frame) void;
//   pub const DeviceInfo = struct {
//       name: [:0]const u8,                    -- backend-native device id
//       description: [:0]const u8,             -- human-readable label
//       pub fn free(self: DeviceInfo, allocator: std.mem.Allocator) void,
//   };
//   pub fn listSources(allocator: std.mem.Allocator) ![]DeviceInfo;
//       Enumerates capturable "desktop audio" devices for a picker UI.
//       Caller owns the returned slice and each entry's strings (free with
//       `DeviceInfo.free`, then `allocator.free` the slice).
//   pub const Capture = struct {
//       pub fn init(
//           io: std.Io,
//           sample_rate: u32,
//           on_chunk: ?ChunkFn,
//           on_chunk_ctx: ?*anyopaque,
//           device: ?[:0]const u8,             -- a DeviceInfo.name, or null
//       ) !*Capture;                           -- for "auto-pick desktop audio"
//       pub fn deinit(self: *Capture) void;
//   };
//
// `Capture.init` spawns a background thread that reads audio continuously
// and calls `on_chunk` once per chunk (small and frequent -- see scope.zig's
// use of it -- rather than buffered for a render tick) until `deinit` stops
// and joins that thread. All of this must be safe to call from any thread;
// `on_chunk` runs on the backend's own capture thread.
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux => @import("audio_backend_linux.zig"),
    .macos => @import("audio_backend_macos.zig"),
    .windows => @import("audio_backend_windows.zig"),
    else => @compileError("no audio capture backend for target OS: " ++ @tagName(builtin.os.tag)),
};

pub const Frame = impl.Frame;
pub const ChunkFn = impl.ChunkFn;
pub const DeviceInfo = impl.DeviceInfo;
pub const Capture = impl.Capture;
pub const listSources = impl.listSources;
