// Linux audio-capture backend: implements the contract documented in
// audio_backend.zig using PulseAudio's client API (also what PipeWire
// exposes via pipewire-pulse, which is what this was developed against).
//
// Records the desktop's default output (via its monitor source) using the
// blocking Simple API on a background thread. Each chunk read from the
// server is handed directly to a caller-supplied callback (see scope.zig)
// instead of being buffered for later -- so rendering never has to catch up
// and no samples get skipped.
const std = @import("std");

const c = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
    @cInclude("pulse/mainloop.h");
    @cInclude("pulse/context.h");
    @cInclude("pulse/introspect.h");
});

pub const Frame = [2]f32;

const chunk_frames = 256;

pub const ChunkFn = *const fn (ctx: ?*anyopaque, frames: []const Frame) void;

pub const Capture = struct {
    simple: *c.pa_simple,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    io: std.Io,
    on_chunk: ?ChunkFn,
    on_chunk_ctx: ?*anyopaque,

    /// `device` is a PulseAudio source name (as returned by `listSources`),
    /// or null to auto-discover the monitor of the default sink (i.e. "just
    /// capture whatever the desktop is playing").
    pub fn init(io: std.Io, sample_rate: u32, on_chunk: ?ChunkFn, on_chunk_ctx: ?*anyopaque, device: ?[:0]const u8) !*Capture {
        const resolved_device = device orelse findMonitorSource();

        var err: c_int = 0;
        const ss = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32NE,
            .rate = sample_rate,
            .channels = 2,
        };

        // PulseAudio's server-chosen default fragsize for record streams is
        // ~2s, which is where the multi-second latency comes from. Request a
        // small fragment explicitly (and let ADJUST_LATENCY, implied by
        // passing a non-null buffer_attr, retarget the whole source path).
        const attr = c.pa_buffer_attr{
            .maxlength = std.math.maxInt(u32),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = chunk_frames * @sizeOf(Frame),
        };

        const simple = c.pa_simple_new(
            null, // default server
            "PragmaticAudio",
            c.PA_STREAM_RECORD,
            if (resolved_device) |d| d.ptr else null,
            "vectorscope capture",
            &ss,
            null,
            &attr,
            &err,
        ) orelse {
            std.debug.print("pa_simple_new failed: {s}\n", .{c.pa_strerror(err)});
            return error.PulseConnectFailed;
        };

        const self = try std.heap.page_allocator.create(Capture);
        self.* = .{
            .simple = simple,
            .thread = undefined,
            .stop_flag = std.atomic.Value(bool).init(false),
            .io = io,
            .on_chunk = on_chunk,
            .on_chunk_ctx = on_chunk_ctx,
        };
        self.thread = try std.Thread.spawn(.{}, captureLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Capture) void {
        self.stop_flag.store(true, .release);
        self.thread.join();
        c.pa_simple_free(self.simple);
        std.heap.page_allocator.destroy(self);
    }

    fn captureLoop(self: *Capture) void {
        var buf: [chunk_frames]Frame = undefined;
        while (!self.stop_flag.load(.acquire)) {
            var err: c_int = 0;
            const rc = c.pa_simple_read(self.simple, &buf, @sizeOf(@TypeOf(buf)), &err);
            if (rc < 0) {
                std.debug.print("pa_simple_read failed: {s}\n", .{c.pa_strerror(err)});
                _ = self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
                continue;
            }

            if (self.on_chunk) |cb| cb(self.on_chunk_ctx, &buf);
        }
    }
};

pub const DeviceInfo = struct {
    name: [:0]const u8,
    description: [:0]const u8,

    pub fn free(self: DeviceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

const SourceListCtx = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(DeviceInfo),
    done: bool = false,
};

/// Enumerates every PulseAudio source (both real input devices and the
/// ".monitor" sources that capture a sink's output), for a device-picker UI.
/// Caller owns the returned slice and each entry's strings.
pub fn listSources(allocator: std.mem.Allocator) ![]DeviceInfo {
    const mainloop = c.pa_mainloop_new() orelse return error.PulseConnectFailed;
    defer c.pa_mainloop_free(mainloop);

    const api = c.pa_mainloop_get_api(mainloop);
    const ctx = c.pa_context_new(api, "PragmaticAudio-devicelist") orelse return error.PulseConnectFailed;
    defer c.pa_context_unref(ctx);

    if (c.pa_context_connect(ctx, null, 0, null) < 0) return error.PulseConnectFailed;

    var slctx = SourceListCtx{ .allocator = allocator, .list = .empty };
    errdefer {
        for (slctx.list.items) |d| d.free(allocator);
        slctx.list.deinit(allocator);
    }

    var query_issued = false;
    while (true) {
        const state = c.pa_context_get_state(ctx);
        if (state == c.PA_CONTEXT_FAILED or state == c.PA_CONTEXT_TERMINATED) break;
        if (state == c.PA_CONTEXT_READY and !query_issued) {
            query_issued = true;
            _ = c.pa_context_get_source_info_list(ctx, sourceInfoCallback, &slctx);
        }
        if (slctx.done) break;
        if (c.pa_mainloop_iterate(mainloop, 1, null) < 0) break;
    }

    c.pa_context_disconnect(ctx);
    return slctx.list.toOwnedSlice(allocator);
}

fn sourceInfoCallback(_: ?*c.pa_context, info: ?*const c.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const slctx: *SourceListCtx = @ptrCast(@alignCast(userdata.?));
    if (eol != 0) {
        slctx.done = true;
        return;
    }
    const i = info orelse return;
    // Skip networked sources (AirPlay/RAOP receivers PipeWire discovers on
    // the LAN, module-raop-discover, etc.) -- they're not audio devices on
    // this machine, and on a busy network there can be dozens of them,
    // burying the real (local) devices in the list.
    if (i.flags & c.PA_SOURCE_NETWORK != 0) return;

    const name = std.mem.span(i.name);
    const desc = if (i.description) |d| std.mem.span(d) else name;

    const owned_name = slctx.allocator.dupeZ(u8, name) catch return;
    const owned_desc = slctx.allocator.dupeZ(u8, desc) catch {
        slctx.allocator.free(owned_name);
        return;
    };
    slctx.list.append(slctx.allocator, .{ .name = owned_name, .description = owned_desc }) catch {
        slctx.allocator.free(owned_name);
        slctx.allocator.free(owned_desc);
    };
}

/// Looks up the monitor source of the default sink (i.e. "desktop audio")
/// via a short-lived pa_mainloop connection. Returns null (meaning "use
/// PulseAudio's default source") if discovery fails for any reason.
fn findMonitorSource() ?[:0]const u8 {
    const mainloop = c.pa_mainloop_new() orelse return null;
    defer c.pa_mainloop_free(mainloop);

    const api = c.pa_mainloop_get_api(mainloop);
    const ctx = c.pa_context_new(api, "PragmaticAudio-discovery") orelse return null;
    defer c.pa_context_unref(ctx);

    if (c.pa_context_connect(ctx, null, 0, null) < 0) return null;

    const State = struct {
        var result_buf: [512]u8 = undefined;
        var result: ?[:0]const u8 = null;
        var done = false;
    };
    State.result = null;
    State.done = false;

    while (true) {
        const state = c.pa_context_get_state(ctx);
        if (state == c.PA_CONTEXT_FAILED or state == c.PA_CONTEXT_TERMINATED) break;
        if (state == c.PA_CONTEXT_READY and !State.done) {
            State.done = true; // only issue the query once
            _ = c.pa_context_get_server_info(ctx, serverInfoCallback, &State.result);
        }
        if (State.result != null) break;
        if (c.pa_mainloop_iterate(mainloop, 1, null) < 0) break;
    }

    c.pa_context_disconnect(ctx);
    return State.result;
}

const monitor_suffix = ".monitor";
var monitor_name_buf: [512]u8 = undefined;

fn serverInfoCallback(_: ?*c.pa_context, info: ?*const c.pa_server_info, userdata: ?*anyopaque) callconv(.c) void {
    const out: *?[:0]const u8 = @ptrCast(@alignCast(userdata.?));
    const sink_name = if (info) |i| i.default_sink_name else null;
    if (sink_name) |name| {
        const len = std.mem.len(name);
        if (len + monitor_suffix.len < monitor_name_buf.len) {
            @memcpy(monitor_name_buf[0..len], name[0..len]);
            @memcpy(monitor_name_buf[len .. len + monitor_suffix.len], monitor_suffix);
            monitor_name_buf[len + monitor_suffix.len] = 0;
            out.* = monitor_name_buf[0 .. len + monitor_suffix.len :0];
        }
    }
}
