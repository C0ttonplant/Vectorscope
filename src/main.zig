// raylib-zig (c) Nikolas Wipper 2023
const std = @import("std");
const rl = @import("raylib");
const audio = @import("audio_backend.zig");
const scope_mod = @import("scope.zig");
const settings_panel = @import("settings_panel.zig");
const Scope = scope_mod.Scope;
const Settings = scope_mod.Settings;

var io: std.Io = undefined;

const sample_rate = 48000;
const scope_width = 700;
const scope_height = 700;
const min_window_size = 300;

var capture: *audio.Capture = undefined;
var scope: *Scope = undefined;
var settings: Settings = .{};
var texture_pixels: []u8 = undefined;
var texture: rl.Texture2D = undefined;

pub fn main(initt: std.process.Init) anyerror!void {
    // Initialization
    //--------------------------------------------------------------------------------------
    const screenWidth = 900;
    const screenHeight = 800;
    io = initt.io;

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_resizable = true });
    rl.initWindow(screenWidth, screenHeight, "Vectorscope");
    defer rl.closeWindow(); // Close window and OpenGL context
    rl.setWindowMinSize(min_window_size, min_window_size);
    setWindowIcon();

    rl.setTargetFPS(60);
    //--------------------------------------------------------------------------------------

    try init(initt.gpa);
    defer deinit(initt.gpa);

    var hud_visible = true;

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Update
        //----------------------------------------------------------------------------------
        scope.snapshot(texture_pixels);
        rl.updateTexture(texture, texture_pixels.ptr);

        if (rl.isKeyPressed(.h)) hud_visible = !hud_visible;
        if (rl.isKeyPressed(.b)) {
            if (rl.isWindowState(.{ .window_undecorated = true })) {
                rl.clearWindowState(.{ .window_undecorated = true });
            } else {
                rl.setWindowState(.{ .window_undecorated = true });
            }
        }
        if (rl.isKeyPressed(.f11)) rl.toggleBorderlessWindowed();

        // The scope is always square: the largest square that fits the
        // current (resizable) window, centered on the other axis.
        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        const side = @min(screen_w, screen_h);
        const dest_rect = rl.Rectangle{
            .x = (screen_w - side) / 2.0,
            .y = (screen_h - side) / 2.0,
            .width = side,
            .height = side,
        };
        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color{ .a = 255, .b = 17, .g = 6, .r = 3 });
        rl.drawTexturePro(
            texture,
            .{ .x = 0, .y = 0, .width = scope_width, .height = scope_height },
            dest_rect,
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );

        if (settings_panel.update(&settings, hud_visible)) |change| {
            if (audio.Capture.init(io, sample_rate, Scope.onChunk, scope, change.device)) |new_capture| {
                capture.deinit();
                capture = new_capture;
            } else |err| {
                std.debug.print("Failed to switch audio device: {}\n", .{err});
            }
        }
        if (hud_visible) rl.drawFPS(rl.getScreenWidth() - 90, 10);
        //----------------------------------------------------------------------------------
    }
}

// GLFW/raylib don't support setting a per-window icon on Wayland at all
// (there is no such protocol call) -- the compositor picks it up from the
// installed .desktop file's Icon= entry instead (see assets/README, or the
// install step run alongside this build). This still sets it for X11
// sessions and window-decoration title bars.
const icon_png_16 = @embedFile("assets/icon-16.png");
const icon_png_32 = @embedFile("assets/icon-32.png");
const icon_png_48 = @embedFile("assets/icon-48.png");
const icon_png_64 = @embedFile("assets/icon-64.png");
const icon_png_128 = @embedFile("assets/icon-128.png");
const icon_png_256 = @embedFile("assets/icon-256.png");

fn setWindowIcon() void {
    var images: [6]rl.Image = undefined;
    const sources = [_][]const u8{ icon_png_16, icon_png_32, icon_png_48, icon_png_64, icon_png_128, icon_png_256 };
    var loaded: usize = 0;
    for (sources) |data| {
        images[loaded] = rl.loadImageFromMemory(".png", data) catch continue;
        loaded += 1;
    }
    defer for (images[0..loaded]) |image| rl.unloadImage(image);
    if (loaded > 0) rl.setWindowIcons(images[0..loaded]);
}

fn init(gpa: std.mem.Allocator) anyerror!void {
    scope = try Scope.init(io, gpa, scope_width, scope_height, &settings);
    texture_pixels = try gpa.alloc(u8, @as(usize, scope_width * scope_height * 4));

    const image = rl.Image{
        .data = scope.pixels.ptr,
        .width = scope_width,
        .height = scope_height,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    texture = try rl.loadTextureFromImage(image);

    settings_panel.init(gpa);
    capture = try audio.Capture.init(io, sample_rate, Scope.onChunk, scope, null);
}

fn deinit(gpa: std.mem.Allocator) void {
    capture.deinit();
    settings_panel.deinit(gpa);
    rl.unloadTexture(texture);
    gpa.free(texture_pixels);
    scope.deinit(gpa);
}
