// Software-rasterized vectorscope. Samples are drawn into a plain CPU pixel
// buffer directly from the audio-capture backend's chunk callback (see
// audio_backend.zig) as soon as each chunk arrives, instead of waiting for
// the next video frame. The render loop only fades the buffer and uploads
// it to a GPU texture.
const std = @import("std");
const rl = @import("raylib");
const audio = @import("audio_backend.zig");

pub const Settings = struct {
    zoom: std.atomic.Value(f32) = .init(1.0),
    /// Fraction of brightness kept each video frame (0 = no trail, close to 1 = long trail).
    persistence: std.atomic.Value(f32) = .init(0.85),
    cursor_size: std.atomic.Value(f32) = .init(1.5),
    color: std.atomic.Value(u32) = .init(colorToU32(.{ .r = 0, .g = 255, .b = 90, .a = 255 })),
};

pub fn colorToU32(col: rl.Color) u32 {
    return (@as(u32, col.r) << 24) | (@as(u32, col.g) << 16) | (@as(u32, col.b) << 8) | col.a;
}

pub fn u32ToColor(v: u32) rl.Color {
    return .{
        .r = @truncate(v >> 24),
        .g = @truncate(v >> 16),
        .b = @truncate(v >> 8),
        .a = @truncate(v),
    };
}

fn dimColor(col: rl.Color, factor: f32) rl.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(col.r)) * factor),
        .g = @intFromFloat(@as(f32, @floatFromInt(col.g)) * factor),
        .b = @intFromFloat(@as(f32, @floatFromInt(col.b)) * factor),
        .a = col.a,
    };
}

fn lerpColor(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    return .{
        .r = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(a.r)), @as(f32, @floatFromInt(b.r)), t)),
        .g = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(a.g)), @as(f32, @floatFromInt(b.g)), t)),
        .b = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(a.b)), @as(f32, @floatFromInt(b.b)), t)),
        .a = a.a,
    };
}

/// Hard ceiling on stamp() calls per audio chunk, regardless of zoom,
/// amplitude, or how much of the signal crosses the canvas. See onChunk.
const max_stamps_per_chunk: u32 = 4_096;

pub const Scope = struct {
    width: i32,
    height: i32,
    pixels: []u8, // RGBA8, width * height * 4
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    settings: *Settings,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, width: i32, height: i32, settings: *Settings) !*Scope {
        const pixels = try allocator.alloc(u8, @as(usize, @intCast(width * height * 4)));
        @memset(pixels, 255);

        const self = try allocator.create(Scope);
        self.* = .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .io = io,
            .settings = settings,
        };
        return self;
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.destroy(self);
    }

    var prev: ?[2]f32 = null;
    /// PulseAudio chunk callback. Runs on the capture thread, once per chunk
    /// (every ~5ms) -- every sample gets rasterized, none are skipped
    /// because we're not gated by the video frame rate.
    pub fn onChunk(ctx: ?*anyopaque, frames: []const audio.Frame) void {
        const self: *Scope = @ptrCast(@alignCast(ctx.?));

        // `persistence` is the fraction kept over one whole video frame
        // (~16.7ms), but chunks arrive faster than that (~5.3ms each). Scale
        // the per-chunk keep factor by this chunk's share of a frame so the
        // fade rate stays the same regardless of chunk size/rate -- fading
        // a little on every chunk instead of a lot once per frame is what
        // avoids the chunky look, without fading faster overall.
        const persistence = std.math.clamp(self.settings.persistence.load(.monotonic), 0.0, 0.98);
        self.fade(persistence);

        const zoom = self.settings.zoom.load(.monotonic);
        const radius = self.settings.cursor_size.load(.monotonic);
        const picked_color = u32ToColor(self.settings.color.load(.monotonic));
        // Since drawing blends with `max()` rather than true alpha
        // compositing, opacity is applied as brightness up front: a
        // half-opaque trace is just a dimmer one against the black canvas.
        const opacity = @as(f32, @floatFromInt(picked_color.a)) / 255.0;
        const color = dimColor(picked_color, opacity);
        // The gradient spans the whole chunk, not each individual segment:
        // sample 0 (oldest) is exactly as dim as what fade() just left the
        // previous chunk's endpoint at, and it brightens up to the true
        // color by the newest sample. Lerping from faded to true color
        // within every tiny segment instead of across the whole chunk is
        // what caused the repeating, chunky-looking ramp.
        const faded_color = dimColor(color, persistence);

        const cx = @as(f32, @floatFromInt(self.width)) / 2.0;
        const cy = @as(f32, @floatFromInt(self.height)) / 2.0;
        const scale = (@as(f32, @floatFromInt(self.height)) / 2.2) * zoom;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Canvas clipping (in drawSegment) bounds any single segment's cost
        // to roughly the canvas size, regardless of zoom or amplitude. But a
        // pathological signal that swings between opposite extremes on every
        // sample can still make *every one* of a chunk's ~255 segments cross
        // the whole canvas, which adds up. This hard ceiling on total work
        // per chunk is the backstop: real audio never gets remotely close to
        // it, so it never affects normal playback, but it guarantees this
        // call can't blow past its ~5ms time budget no matter what's fed in.
        var budget: u32 = max_stamps_per_chunk;

        const last_idx = frames.len - 1;
        var prev_color = faded_color;
        for (frames, 0..) |frame, idx| {
            const x = cx + frame[0] * scale;
            const y = cy - frame[1] * scale;
            const t = if (last_idx > 0) @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(last_idx)) else 1.0;
            const cur_color = lerpColor(faded_color, color, t);
            if (budget > 0) {
                if (prev) |p| {
                    budget -= self.drawSegment(p[0], p[1], x, y, radius, prev_color, cur_color, budget);
                } else {
                    self.stamp(x, y, radius, cur_color);
                    budget -= 1;
                }
            }
            prev = .{ x, y };
            prev_color = cur_color;
        }
    }

    /// Draws the segment, spending at most `budget` stamps, and returns how
    /// many it actually spent.
    fn drawSegment(self: *Scope, x0: f32, y0: f32, x1: f32, y1: f32, radius: f32, from_color: rl.Color, to_color: rl.Color, budget: u32) u32 {
        const ri = @max(radius, 0.5);
        const dx = x1 - x0;
        const dy = y1 - y0;

        // At high zoom, a loud/fast-moving signal can land samples
        // thousands of pixels outside the canvas, and the raw sample-to
        // -sample distance no longer bounds how much work drawing this
        // segment takes -- it did when steps were just `ceil(dist)`, which
        // is what let a handful of loud samples balloon into millions of
        // stamp() calls for one ~5ms audio chunk (this all runs on the
        // audio thread, holding the mutex the render thread also needs).
        // Clipping to the (radius-padded) canvas first bounds the visible
        // portion of any segment by the canvas size, regardless of zoom or
        // amplitude, so the step count derived from it is bounded too.
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        const clip = clipToCanvas(dx, dy, x0 + ri, (w + ri) - x0, y0 + ri, (h + ri) - y0) orelse return 0;

        const dist = @sqrt(dx * dx + dy * dy) * (clip[1] - clip[0]);
        // `steps + 1` stamps get drawn below, so cap `steps` one short of
        // `budget` -- otherwise this can return budget+1 and underflow the
        // caller's `budget -= ...`.
        const steps: u32 = @min(@as(u32, @intFromFloat(@max(1.0, @ceil(dist)))), budget - 1);
        for (0..steps + 1) |i| {
            const local_t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const t = clip[0] + (clip[1] - clip[0]) * local_t;
            self.stamp(x0 + dx * t, y0 + dy * t, radius, lerpColor(from_color, to_color, t));
        }
        return steps + 1;
    }

    /// Liang-Barsky line clipping: returns the sub-range of `t` in [0,1]
    /// (start point + t*(dx,dy)) that falls within a rectangle, given as
    /// signed distances from the start point to each of its 4 edges along
    /// -dx, dx, -dy, dy. Returns null if the segment misses the rectangle
    /// entirely.
    fn clipToCanvas(dx: f32, dy: f32, to_left: f32, to_right: f32, to_top: f32, to_bottom: f32) ?[2]f32 {
        var t0: f32 = 0.0;
        var t1: f32 = 1.0;
        const edges = [4][2]f32{ .{ -dx, to_left }, .{ dx, to_right }, .{ -dy, to_top }, .{ dy, to_bottom } };
        for (edges) |edge| {
            const p = edge[0];
            const q = edge[1];
            if (p == 0) {
                if (q < 0) return null;
            } else {
                const r = q / p;
                if (p < 0) {
                    if (r > t1) return null;
                    if (r > t0) t0 = r;
                } else {
                    if (r < t0) return null;
                    if (r < t1) t1 = r;
                }
            }
        }
        return .{ t0, t1 };
    }

    fn stamp(self: *Scope, fx: f32, fy: f32, radius: f32, color: rl.Color) void {
        const ri = @max(radius, 0.5);
        const r2 = ri * ri;
        const col_vec: @Vector(4, u8) = .{ color.r, color.g, color.b, 255 };

        const min_y: i32 = @max(@as(i32, @floor(fy - ri)), 0);
        const max_y: i32 = @min(@as(i32, @ceil(fy + ri)), self.height - 1);

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            const dy = (@as(f32, @floatFromInt(y)) + 0.5) - fy;
            const dy2 = dy * dy;
            // Rows entirely outside the disc (possible since min_y/max_y are
            // clamped to the canvas, not to the actual circle) contribute no
            // pixels -- skip straight to the next row.
            if (dy2 > r2) continue;

            // Per-pixel dx*dx+dy*dy<=r2 tests are equivalent to a single
            // sqrt per row: solve for the exact x range once and fill it
            // directly, instead of visiting every cell of the bounding box
            // and branching on most of them.
            const half_w = @sqrt(r2 - dy2);
            const min_x: i32 = @max(@as(i32, @ceil(fx - half_w - 0.5)), 0);
            const max_x: i32 = @min(@as(i32, @floor(fx + half_w - 0.5)), self.width - 1);
            if (min_x > max_x) continue;

            const row_offset: usize = @intCast(y * self.width);
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const idx = (row_offset + @as(usize, @intCast(x))) * 4;
                // Blend all 4 channels (alpha is always 255, untouched) in
                // one vector op instead of three separate byte load/max/store
                // round trips.
                const pixel: *[4]u8 = @ptrCast(&self.pixels[idx]);
                const cur: @Vector(4, u8) = pixel.*;
                pixel.* = @max(cur, col_vec);
            }
        }
    }

    /// Fades the whole buffer toward black by `keep` (0..1), the fraction of
    /// brightness to retain for this call.
    fn fade(self: *Scope, keep_factor: f32) void {
        const keep: u16 = @intFromFloat(std.math.clamp(keep_factor, 0.0, 1.0) * 255.0);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // This runs on the audio thread once per chunk (~190/sec) over every
        // pixel in the canvas, so it has to be cheap: an integer divide per
        // channel per pixel here was, by far, the most expensive thing this
        // thread was doing while holding the mutex the render thread also
        // needs -- long enough to stutter a frame if the OS didn't schedule
        // this thread back promptly. `>> 8` (divide by 256 instead of 255)
        // is indistinguishable here and is a single cycle instead of dozens.
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = @intCast((@as(u16, self.pixels[i + 0]) * keep) >> 8);
            self.pixels[i + 1] = @intCast((@as(u16, self.pixels[i + 1]) * keep) >> 8);
            self.pixels[i + 2] = @intCast((@as(u16, self.pixels[i + 2]) * keep) >> 8);
        }
    }

    /// Copies the pixel buffer into `out` under lock, so the (slower) GPU
    /// texture upload can happen without blocking the capture thread.
    pub fn snapshot(self: *Scope, out: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memcpy(out, self.pixels);
    }
};
