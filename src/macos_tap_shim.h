// Tiny C-callable wrapper around the parts of Core Audio's Process Tap API
// that are Objective-C only (CATapDescription has no plain-C constructor).
// See macos_tap_shim.m for the implementation and version/API notes.
#ifndef PRAGMATICAUDIO_MACOS_TAP_SHIM_H
#define PRAGMATICAUDIO_MACOS_TAP_SHIM_H

#ifdef __OBJC__

// The Objective-C shim is compiled by Clang, which understands the whole SDK.
#include <CoreAudio/CoreAudio.h>

#else

// ...but Zig 0.16's translate-c (the Aro-based C frontend behind @cImport)
// cannot parse Clang block syntax, and <CoreAudio/AudioHardware.h> declares
// two block typedefs (AudioObjectPropertyListenerBlock at line ~162 and
// AudioDeviceIOBlock at ~832). Including it from @cImport fails with a wall
// of "expected ';', found ')'" errors pointing into the SDK.
//
// AudioHardwareBase.h is block-free and carries every type and selector
// constant we need; the handful of AudioHardware.h functions and constants
// this backend uses are re-declared by hand below. Keep in sync with the SDK.
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CFDictionary.h>

#define kAudioObjectSystemObject 1
#define kAudioTapPropertyUID 0x74756964u /* 'tuid' */
#define kAudioHardwarePropertyDevices 0x64657623u /* 'dev#' */
#define kAudioHardwarePropertyDeviceForUID 0x64756964u /* 'duid' */

#define kAudioAggregateDeviceUIDKey          "uid"
#define kAudioAggregateDeviceNameKey         "name"
#define kAudioAggregateDeviceIsPrivateKey    "private"
#define kAudioAggregateDeviceTapListKey      "taps"
#define kAudioAggregateDeviceTapAutoStartKey "tapautostart"
#define kAudioSubTapUIDKey                   "uid"
#define kAudioSubTapDriftCompensationKey     "drift"

typedef OSStatus (*AudioDeviceIOProc)(AudioObjectID          inDevice,
                                      const AudioTimeStamp*  inNow,
                                      const AudioBufferList* inInputData,
                                      const AudioTimeStamp*  inInputTime,
                                      AudioBufferList*       outOutputData,
                                      const AudioTimeStamp*  inOutputTime,
                                      void*                  inClientData);
typedef AudioDeviceIOProc AudioDeviceIOProcID;

extern OSStatus AudioObjectGetPropertyDataSize(AudioObjectID                     inObjectID,
                                               const AudioObjectPropertyAddress* inAddress,
                                               UInt32                            inQualifierDataSize,
                                               const void*                       inQualifierData,
                                               UInt32*                           outDataSize);

extern OSStatus AudioObjectGetPropertyData(AudioObjectID                     inObjectID,
                                           const AudioObjectPropertyAddress* inAddress,
                                           UInt32                            inQualifierDataSize,
                                           const void*                       inQualifierData,
                                           UInt32*                           ioDataSize,
                                           void*                             outData);

extern OSStatus AudioDeviceCreateIOProcID(AudioObjectID        inDevice,
                                          AudioDeviceIOProc    inProc,
                                          void*                inClientData,
                                          AudioDeviceIOProcID* outIOProcID);

extern OSStatus AudioDeviceDestroyIOProcID(AudioObjectID inDevice, AudioDeviceIOProcID inIOProcID);

extern OSStatus AudioDeviceStart(AudioObjectID inDevice, AudioDeviceIOProcID inProcID);
extern OSStatus AudioDeviceStop(AudioObjectID inDevice, AudioDeviceIOProcID inProcID);

extern OSStatus AudioHardwareCreateAggregateDevice(CFDictionaryRef inDescription, AudioObjectID* outDeviceID);
extern OSStatus AudioHardwareDestroyAggregateDevice(AudioObjectID inDeviceID);

#endif // __OBJC__

// Creates a process tap that mixes the *entire* system's audio output down
// to stereo -- the equivalent of a PulseAudio monitor source. Returns
// kAudioObjectUnknown (0) on failure.
AudioObjectID pa_create_system_tap(void);

// Destroys a tap created by pa_create_system_tap. No-op if tap_id is
// kAudioObjectUnknown.
void pa_destroy_system_tap(AudioObjectID tap_id);

#endif
