// Tiny C-callable wrapper around the parts of Core Audio's Process Tap API
// that are Objective-C only (CATapDescription has no plain-C constructor).
// See macos_tap_shim.m for the implementation and version/API notes.
#ifndef PRAGMATICAUDIO_MACOS_TAP_SHIM_H
#define PRAGMATICAUDIO_MACOS_TAP_SHIM_H

#include <CoreAudio/CoreAudio.h>

// Creates a process tap that mixes the *entire* system's audio output down
// to stereo -- the equivalent of a PulseAudio monitor source. Returns
// kAudioObjectUnknown (0) on failure.
AudioObjectID pa_create_system_tap(void);

// Destroys a tap created by pa_create_system_tap. No-op if tap_id is
// kAudioObjectUnknown.
void pa_destroy_system_tap(AudioObjectID tap_id);

#endif
