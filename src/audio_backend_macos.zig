// macOS audio-capture backend, using Core Audio Process Taps (macOS 14.4+)
// to capture desktop audio without a virtual driver -- the equivalent of a
// PulseAudio monitor source. See audio_backend.zig for the contract every
// backend must implement.
//
// UNVERIFIED: this was written against documented/publicly known Core Audio
// APIs (the HAL device-enumeration calls are long-stable; the Process Tap
// and aggregate-device-with-tap-list calls are newer and were cross-checked
// against Apple's WWDC23 session 10141 and its accompanying sample code
// structure) but has never been compiled -- there is no macOS SDK available
// in the environment this was written in. `macos_tap_shim.m` carries the
// same caveat for the Objective-C-only CATapDescription piece. Build this on
// an actual Mac and expect to fix real compiler errors; the aggregate
// -device dictionary keys are the most likely spot for a mismatch.
//
// Capture.init requires the user to grant audio-recording permission the
// first time (a system prompt, same as microphone access) since this reads
// the whole system's audio.
const std = @import("std");

const c = @cImport({
    @cInclude("CoreAudio/CoreAudio.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("macos_tap_shim.h");
});

pub const Frame = [2]f32;
pub const ChunkFn = *const fn (ctx: ?*anyopaque, frames: []const Frame) void;

pub const DeviceInfo = struct {
    name: [:0]const u8, // the device's CoreAudio UID
    description: [:0]const u8,

    pub fn free(self: DeviceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

/// Enumerates real input-capable hardware devices (microphones, audio
/// interfaces, etc). The "capture the whole desktop" option isn't a device
/// in this list -- it's what `device: null` resolves to in `Capture.init`,
/// same as the Linux backend's "auto" behavior.
pub fn listSources(allocator: std.mem.Allocator) ![]DeviceInfo {
    var list: std.ArrayList(DeviceInfo) = .empty;
    errdefer {
        for (list.items) |d| d.free(allocator);
        list.deinit(allocator);
    }

    const devices_addr = c.AudioObjectPropertyAddress{
        .mSelector = c.kAudioHardwarePropertyDevices,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };

    var data_size: c.UInt32 = 0;
    if (c.AudioObjectGetPropertyDataSize(c.kAudioObjectSystemObject, &devices_addr, 0, null, &data_size) != 0) {
        return list.toOwnedSlice(allocator);
    }

    const count = data_size / @sizeOf(c.AudioObjectID);
    const device_ids = try allocator.alloc(c.AudioObjectID, count);
    defer allocator.free(device_ids);

    if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &devices_addr, 0, null, &data_size, device_ids.ptr) != 0) {
        return list.toOwnedSlice(allocator);
    }

    for (device_ids) |device_id| {
        // Skip devices with no input side (e.g. a plain output-only speaker).
        const stream_addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyStreams,
            .mScope = c.kAudioObjectPropertyScopeInput,
            .mElement = c.kAudioObjectPropertyElementMain,
        };
        var stream_size: c.UInt32 = 0;
        if (c.AudioObjectGetPropertyDataSize(device_id, &stream_addr, 0, null, &stream_size) != 0) continue;
        if (stream_size == 0) continue;

        const uid = (try getStringProperty(allocator, device_id, c.kAudioDevicePropertyDeviceUID)) orelse continue;
        const name = (try getStringProperty(allocator, device_id, c.kAudioObjectPropertyName)) orelse {
            allocator.free(uid);
            continue;
        };

        list.append(allocator, .{ .name = uid, .description = name }) catch {
            allocator.free(uid);
            allocator.free(name);
        };
    }

    return list.toOwnedSlice(allocator);
}

fn getStringProperty(allocator: std.mem.Allocator, object_id: c.AudioObjectID, selector: c.AudioObjectPropertySelector) !?[:0]u8 {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = selector,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var cf_string: c.CFStringRef = null;
    var size: c.UInt32 = @sizeOf(c.CFStringRef);
    if (c.AudioObjectGetPropertyData(object_id, &addr, 0, null, &size, &cf_string) != 0 or cf_string == null) {
        return null;
    }
    defer c.CFRelease(cf_string);

    const max_bytes: usize = @intCast(c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(cf_string), c.kCFStringEncodingUTF8) + 1);
    const scratch = try allocator.alloc(u8, max_bytes);
    defer allocator.free(scratch);
    if (c.CFStringGetCString(cf_string, scratch.ptr, @intCast(scratch.len), c.kCFStringEncodingUTF8) == 0) {
        return null;
    }
    const len = std.mem.len(@as([*:0]const u8, @ptrCast(scratch.ptr)));
    return try allocator.dupeZ(u8, scratch[0..len]);
}

/// Resolves a device UID (as returned by `listSources`) back to the
/// AudioObjectID Core Audio actually uses for I/O calls.
fn deviceIdForUID(uid: [:0]const u8) !c.AudioObjectID {
    const cf_uid = c.CFStringCreateWithCString(null, uid.ptr, c.kCFStringEncodingUTF8) orelse return error.CoreAudioCFStringFailed;
    defer c.CFRelease(cf_uid);

    var device_id: c.AudioObjectID = c.kAudioObjectUnknown;
    var translation = c.AudioValueTranslation{
        .mInputData = @constCast(@ptrCast(&cf_uid)),
        .mInputDataSize = @sizeOf(c.CFStringRef),
        .mOutputData = @ptrCast(&device_id),
        .mOutputDataSize = @sizeOf(c.AudioObjectID),
    };

    const addr = c.AudioObjectPropertyAddress{
        .mSelector = c.kAudioHardwarePropertyDeviceForUID,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var size: c.UInt32 = @sizeOf(c.AudioValueTranslation);
    if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &addr, 0, null, &size, &translation) != 0 or device_id == c.kAudioObjectUnknown) {
        return error.CoreAudioDeviceNotFound;
    }
    return device_id;
}

/// Wraps a process tap in a private aggregate device -- Core Audio only
/// lets you actually pull audio (via AudioDeviceCreateIOProcID) from a
/// device, and a tap by itself isn't one; this is the documented pattern
/// for making one I/O-capable. `kAudioAggregateDeviceTapListKey` and its
/// per-tap dictionary keys are the newest, least-verified part of this file.
fn createAggregateDeviceForTap(allocator: std.mem.Allocator, tap_id: c.AudioObjectID) !c.AudioObjectID {
    const tap_uid = (try getStringProperty(allocator, tap_id, c.kAudioTapPropertyUID)) orelse return error.CoreAudioTapUIDFailed;
    defer allocator.free(tap_uid);

    const cf_tap_uid = c.CFStringCreateWithCString(null, tap_uid.ptr, c.kCFStringEncodingUTF8) orelse return error.CoreAudioCFStringFailed;
    defer c.CFRelease(cf_tap_uid);
    const cf_device_uid = c.CFStringCreateWithCString(null, "com.pragmaticaudio.systemtap", c.kCFStringEncodingUTF8) orelse return error.CoreAudioCFStringFailed;
    defer c.CFRelease(cf_device_uid);
    const cf_device_name = c.CFStringCreateWithCString(null, "PragmaticAudio Tap", c.kCFStringEncodingUTF8) orelse return error.CoreAudioCFStringFailed;
    defer c.CFRelease(cf_device_name);

    const sub_tap_keys = [_]c.CFStringRef{ c.kAudioSubTapUIDKey, c.kAudioSubTapDriftCompensationKey };
    const sub_tap_values = [_]?*const anyopaque{ cf_tap_uid, c.kCFBooleanTrue };
    const sub_tap_dict = c.CFDictionaryCreate(
        null,
        @ptrCast(&sub_tap_keys),
        @ptrCast(&sub_tap_values),
        sub_tap_keys.len,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return error.CoreAudioCFDictionaryFailed;
    defer c.CFRelease(sub_tap_dict);

    const tap_list_values = [_]?*const anyopaque{sub_tap_dict};
    const tap_list = c.CFArrayCreate(null, @ptrCast(&tap_list_values), 1, &c.kCFTypeArrayCallBacks) orelse return error.CoreAudioCFArrayFailed;
    defer c.CFRelease(tap_list);

    const top_keys = [_]c.CFStringRef{
        c.kAudioAggregateDeviceNameKey,
        c.kAudioAggregateDeviceUIDKey,
        c.kAudioAggregateDeviceIsPrivateKey,
        c.kAudioAggregateDeviceTapAutoStartKey,
        c.kAudioAggregateDeviceTapListKey,
    };
    const top_values = [_]?*const anyopaque{
        cf_device_name, cf_device_uid, c.kCFBooleanTrue, c.kCFBooleanTrue, tap_list,
    };
    const description_dict = c.CFDictionaryCreate(
        null,
        @ptrCast(&top_keys),
        @ptrCast(&top_values),
        top_keys.len,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return error.CoreAudioCFDictionaryFailed;
    defer c.CFRelease(description_dict);

    var device_id: c.AudioObjectID = c.kAudioObjectUnknown;
    if (c.AudioHardwareCreateAggregateDevice(description_dict, &device_id) != 0) {
        return error.CoreAudioAggregateDeviceFailed;
    }
    return device_id;
}

pub const Capture = struct {
    on_chunk: ?ChunkFn,
    on_chunk_ctx: ?*anyopaque,
    device_id: c.AudioObjectID,
    io_proc_id: c.AudioDeviceIOProcID,
    aggregate_device_id: c.AudioObjectID, // kAudioObjectUnknown unless using a tap
    tap_id: c.AudioObjectID, // kAudioObjectUnknown unless using a tap

    /// `device` is a UID from `listSources` to capture a real input device
    /// directly, or null to tap the whole system's audio output (the usual
    /// "desktop audio" case, and what "Auto" in the settings UI means).
    pub fn init(io: std.Io, sample_rate: u32, on_chunk: ?ChunkFn, on_chunk_ctx: ?*anyopaque, device: ?[:0]const u8) !*Capture {
        _ = io; // Core Audio drives the IOProc on its own real-time thread; no thread of our own to run.
        _ = sample_rate; // Devices/taps run at their own negotiated rate -- see file header note.

        var aggregate_device_id: c.AudioObjectID = c.kAudioObjectUnknown;
        var tap_id: c.AudioObjectID = c.kAudioObjectUnknown;
        var target_device_id: c.AudioObjectID = c.kAudioObjectUnknown;

        if (device) |uid| {
            target_device_id = try deviceIdForUID(uid);
        } else {
            tap_id = c.pa_create_system_tap();
            if (tap_id == c.kAudioObjectUnknown) return error.CoreAudioTapFailed;
            aggregate_device_id = createAggregateDeviceForTap(std.heap.page_allocator, tap_id) catch |err| {
                c.pa_destroy_system_tap(tap_id);
                return err;
            };
            target_device_id = aggregate_device_id;
        }

        const self = try std.heap.page_allocator.create(Capture);
        self.* = .{
            .on_chunk = on_chunk,
            .on_chunk_ctx = on_chunk_ctx,
            .device_id = target_device_id,
            .io_proc_id = null,
            .aggregate_device_id = aggregate_device_id,
            .tap_id = tap_id,
        };

        var io_proc_id: c.AudioDeviceIOProcID = null;
        if (c.AudioDeviceCreateIOProcID(target_device_id, ioProc, self, &io_proc_id) != 0) {
            self.teardownDeviceGraph();
            std.heap.page_allocator.destroy(self);
            return error.CoreAudioIOProcFailed;
        }
        self.io_proc_id = io_proc_id;

        if (c.AudioDeviceStart(target_device_id, io_proc_id) != 0) {
            _ = c.AudioDeviceDestroyIOProcID(target_device_id, io_proc_id);
            self.teardownDeviceGraph();
            std.heap.page_allocator.destroy(self);
            return error.CoreAudioStartFailed;
        }

        return self;
    }

    pub fn deinit(self: *Capture) void {
        _ = c.AudioDeviceStop(self.device_id, self.io_proc_id);
        _ = c.AudioDeviceDestroyIOProcID(self.device_id, self.io_proc_id);
        self.teardownDeviceGraph();
        std.heap.page_allocator.destroy(self);
    }

    fn teardownDeviceGraph(self: *Capture) void {
        if (self.aggregate_device_id != c.kAudioObjectUnknown) {
            _ = c.AudioHardwareDestroyAggregateDevice(self.aggregate_device_id);
        }
        if (self.tap_id != c.kAudioObjectUnknown) {
            c.pa_destroy_system_tap(self.tap_id);
        }
    }
};

/// Called by Core Audio on its own real-time I/O thread whenever a buffer
/// is ready -- same "draw as it arrives, not once per video frame" model as
/// the Linux backend's capture thread, just driven by the OS instead of a
/// thread we spawn ourselves. Must return quickly: this shares a real-time
/// priority thread with the rest of the system's audio I/O.
fn ioProc(
    in_device: c.AudioObjectID,
    in_now: [*c]const c.AudioTimeStamp,
    in_input_data: [*c]const c.AudioBufferList,
    in_input_time: [*c]const c.AudioTimeStamp,
    out_output_data: [*c]c.AudioBufferList,
    in_output_time: [*c]const c.AudioTimeStamp,
    in_client_data: ?*anyopaque,
) callconv(.c) c.OSStatus {
    _ = .{ in_device, in_now, in_input_time, out_output_data, in_output_time };
    const self: *Capture = @ptrCast(@alignCast(in_client_data.?));
    const cb = self.on_chunk orelse return 0;
    const buffer_list = in_input_data orelse return 0;
    if (buffer_list.*.mNumberBuffers == 0) return 0;

    // Assumes the tap/device negotiated interleaved stereo Float32, Core
    // Audio's usual canonical format for a stereo mixdown -- worth
    // double-checking against the stream format actually negotiated if
    // this comes out garbled or at the wrong pitch/speed.
    const buf = buffer_list.*.mBuffers[0];
    const frame_count = buf.mDataByteSize / @sizeOf(Frame);
    const data: [*]Frame = @ptrCast(@alignCast(buf.mData));
    cb(self.on_chunk_ctx, data[0..frame_count]);
    return 0;
}
