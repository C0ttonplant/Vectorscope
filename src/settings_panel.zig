// Hamburger button + settings panel: zoom, persistence, cursor size, trace
// color (with opacity), and audio device. Call `update` once per frame from
// inside the beginDrawing/endDrawing block.
const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const scope = @import("scope.zig");
const audio = @import("audio_backend.zig");

const hamburger_rect = rl.Rectangle{ .x = 12, .y = 12, .width = 32, .height = 32 };
const panel_width = 320.0;
const label_width = 90.0;
const row_h = 24.0;
const row_gap = 10.0;
const margin = 14.0;
// Space the dropdown box's own chrome (the arrow icon plus its left/right
// text padding) eats into `row_w` -- device descriptions get ellipsized to
// fit inside what's left, measured against the actual font in use.
const dropdown_chrome_width = 40.0;

var menu_open = false;
var style_applied = false;

var devices: []audio.DeviceInfo = &.{};
var device_labels: [:0]const u8 = "Auto (Desktop Audio)";
var device_labels_owned = false;
var selected_index: i32 = 0;
var prev_selected_index: i32 = 0;
var dropdown_edit_mode = false;

/// Result of a device pick this frame. `device` is null for "Auto (Desktop
/// Audio)", distinguishing "switched back to auto" from "nothing changed"
/// (which `update` reports by returning null instead of this struct).
pub const DeviceChange = struct { device: ?[:0]const u8 };

/// Fetches the list of available capture devices for the dropdown. Safe to
/// call even if enumeration fails -- the dropdown just falls back to only
/// offering "Auto".
pub fn init(allocator: std.mem.Allocator) void {
    devices = audio.listSources(allocator) catch &.{};
    if (buildDeviceLabels(allocator)) |labels| {
        device_labels = labels;
        device_labels_owned = true;
    } else |_| {
        device_labels = "Auto (Desktop Audio)";
        device_labels_owned = false;
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    for (devices) |d| d.free(allocator);
    allocator.free(devices);
    if (device_labels_owned) allocator.free(device_labels);
}

fn buildDeviceLabels(allocator: std.mem.Allocator) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const max_text_width: f32 = (panel_width - 2 * margin) - dropdown_chrome_width;

    try appendFitted(&buf, allocator, "Auto (Desktop Audio)", max_text_width);
    for (devices) |d| {
        try buf.append(allocator, ';');
        // raygui splits the label list on ';' -- keep device descriptions
        // from accidentally introducing a bogus extra entry.
        var sanitized_buf: [256]u8 = undefined;
        const sanitized_len = @min(d.description.len, sanitized_buf.len);
        for (d.description[0..sanitized_len], 0..) |ch, i| {
            sanitized_buf[i] = if (ch == ';') ',' else ch;
        }
        try appendFitted(&buf, allocator, sanitized_buf[0..sanitized_len], max_text_width);
    }
    return buf.toOwnedSliceSentinel(allocator, 0);
}

/// Appends `text`, ellipsizing it (measured against the actual font/size in
/// use) if it's wider than `max_width` -- otherwise long device descriptions
/// just get cut off flush against the edge of the dropdown box.
fn appendFitted(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_width: f32) !void {
    var scratch: [260]u8 = undefined;
    const full_len = @min(text.len, 256);
    @memcpy(scratch[0..full_len], text[0..full_len]);
    scratch[full_len] = 0;
    if (@as(f32, @floatFromInt(rg.getTextWidth(scratch[0..full_len :0]))) <= max_width) {
        try buf.appendSlice(allocator, text[0..full_len]);
        return;
    }

    const ellipsis = "...";
    var len = full_len;
    while (len > 0) : (len -= 1) {
        @memcpy(scratch[0..len], text[0..len]);
        @memcpy(scratch[len .. len + ellipsis.len], ellipsis);
        scratch[len + ellipsis.len] = 0;
        if (@as(f32, @floatFromInt(rg.getTextWidth(scratch[0 .. len + ellipsis.len :0]))) <= max_width) break;
    }
    try buf.appendSlice(allocator, text[0..len]);
    try buf.appendSlice(allocator, ellipsis);
}

pub fn update(settings: *scope.Settings, visible: bool) ?DeviceChange {
    applyStyleOnce();
    if (!visible) return null;

    if (rl.isMouseButtonPressed(.left) and rl.checkCollisionPointRec(rl.getMousePosition(), hamburger_rect)) {
        menu_open = !menu_open;
    }

    drawHamburgerIcon(hamburger_rect);
    return if (menu_open) drawPanel(hamburger_rect, settings) else null;
}

fn drawHamburgerIcon(rect: rl.Rectangle) void {
    rl.drawRectangleRec(rect, rl.Color{ .r = 40, .g = 40, .b = 40, .a = 220 });
    const bar_h = 4.0;
    const pad = 6.0;
    var i: f32 = 0;
    while (i < 3) : (i += 1) {
        const y = rect.y + pad + i * ((rect.height - 2 * pad - bar_h) / 2.0);
        rl.drawRectangleRec(.{ .x = rect.x + pad, .y = y, .width = rect.width - 2 * pad, .height = bar_h }, rl.Color.white);
    }
}

/// Slider with its label in a fixed-width column to its left, entirely
/// inside `panel_rect` -- raygui's own `textLeft` draws outside the given
/// bounds, which is what was clipping off the left edge of the window.
fn labeledSlider(x: f32, y: f32, width: f32, label: [:0]const u8, value: *f32, min: f32, max: f32) void {
    _ = rg.label(.{ .x = x, .y = y, .width = label_width, .height = row_h }, label);
    _ = rg.sliderBar(.{ .x = x + label_width, .y = y, .width = width - label_width, .height = row_h }, null, null, value, min, max);
}

fn drawPanel(anchor: rl.Rectangle, settings: *scope.Settings) ?DeviceChange {
    const panel_rect = rl.Rectangle{ .x = anchor.x, .y = anchor.y + anchor.height + 6, .width = panel_width, .height = 260 + row_h + row_gap };
    _ = rg.panel(panel_rect, "Settings");

    const row_x = panel_rect.x + margin;
    const row_w = panel_rect.width - 2 * margin;
    var y = panel_rect.y + 30;

    // Reserve the top row for the device dropdown, but draw it last (below)
    // so its expanded list -- which drops down over these rows -- paints on
    // top of them instead of behind them.
    const device_rect = rl.Rectangle{ .x = row_x, .y = y, .width = row_w, .height = row_h };
    y += row_h + row_gap;

    var zoom = settings.zoom.load(.monotonic);
    labeledSlider(row_x, y, row_w, "Zoom", &zoom, 0.2, 10.0);
    settings.zoom.store(zoom, .monotonic);
    y += row_h + row_gap;

    var persistence = settings.persistence.load(.monotonic);
    labeledSlider(row_x, y, row_w, "Persistence", &persistence, 0.0, 0.98);
    settings.persistence.store(persistence, .monotonic);
    y += row_h + row_gap;

    var cursor_size = settings.cursor_size.load(.monotonic);
    labeledSlider(row_x, y, row_w, "Cursor Size", &cursor_size, 0.5, 6.0);
    settings.cursor_size.store(cursor_size, .monotonic);
    y += row_h + row_gap + 4;

    var color = scope.u32ToColor(settings.color.load(.monotonic));
    const picker_size = 96.0;
    const alpha_bar_w = 18.0;
    const hue_bar_w = 18.0;
    const picker_x = row_x;
    _ = rg.colorPicker(.{ .x = picker_x, .y = y, .width = picker_size, .height = picker_size }, "Color", &color);

    var alpha: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
    _ = rg.colorBarAlpha(.{ .x = picker_x + picker_size + hue_bar_w + 16, .y = y, .width = alpha_bar_w, .height = picker_size }, "Opacity", &alpha);
    color.a = @intFromFloat(alpha * 255.0);

    settings.color.store(scope.colorToU32(color), .monotonic);

    if (rg.dropdownBox(device_rect, device_labels, &selected_index, dropdown_edit_mode) != 0) {
        dropdown_edit_mode = !dropdown_edit_mode;
    }
    if (selected_index != prev_selected_index) {
        prev_selected_index = selected_index;
        return .{ .device = deviceNameForIndex(selected_index) };
    }
    return null;
}

fn deviceNameForIndex(index: i32) ?[:0]const u8 {
    if (index <= 0) return null; // "Auto (Desktop Audio)"
    const i: usize = @intCast(index - 1);
    if (i >= devices.len) return null;
    return devices[i].name;
}

/// Nudges raygui's default light theme toward something that doesn't clash
/// with the black scope background: dark panels, light text.
fn applyStyleOnce() void {
    if (style_applied) return;
    style_applied = true;

    const border = colorInt(.{ .r = 70, .g = 70, .b = 70, .a = 255 });
    const base = colorInt(.{ .r = 34, .g = 34, .b = 34, .a = 235 });
    const base_focused = colorInt(.{ .r = 50, .g = 50, .b = 50, .a = 235 });
    const text = colorInt(.{ .r = 230, .g = 230, .b = 230, .a = 255 });
    const background = colorInt(.{ .r = 24, .g = 24, .b = 24, .a = 235 });

    rg.setStyle(.default, .{ .control = .border_color_normal }, border);
    rg.setStyle(.default, .{ .control = .base_color_normal }, base);
    rg.setStyle(.default, .{ .control = .text_color_normal }, text);
    rg.setStyle(.default, .{ .control = .border_color_focused }, border);
    rg.setStyle(.default, .{ .control = .base_color_focused }, base_focused);
    rg.setStyle(.default, .{ .control = .text_color_focused }, text);
    rg.setStyle(.default, .{ .default = .background_color }, background);
}

fn colorInt(col: rl.Color) i32 {
    return @bitCast(scope.colorToU32(col));
}
