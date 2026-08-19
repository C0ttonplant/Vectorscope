// UNVERIFIED: written from Apple's WWDC23 session 10141 ("Adopt Core Audio
// tapping") and the publicly documented Process Tap API, but never compiled
// -- there is no macOS SDK available in the environment this was written
// in. Cross-check against the real <CoreAudio/CATapDescription.h> and
// <CoreAudio/AudioHardwareTapping.h> headers on an actual Mac; the
// initializer name and property names below are the most likely spots for
// a mismatch (e.g. Apple renaming/adjusting something between SDK betas).
//
// Requires macOS 14.4+ (Process Taps landed in 14.2; the CATapDescription
// Objective-C class was documented/public from 14.4).
#import "macos_tap_shim.h"
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

AudioObjectID pa_create_system_tap(void) {
    @autoreleasepool {
        // Empty exclude-list = tap every process, i.e. "the whole desktop".
        CATapDescription *description =
            [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
        description.name = @"PragmaticAudio System Tap";
        description.muteBehavior = CATapUnmuted;
        description.mixdown = YES;
        description.privateTap = YES;

        AudioObjectID tapID = kAudioObjectUnknown;
        OSStatus status = AudioHardwareCreateProcessTap(description, &tapID);
        if (status != noErr) {
            return kAudioObjectUnknown;
        }
        return tapID;
    }
}

void pa_destroy_system_tap(AudioObjectID tap_id) {
    if (tap_id != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tap_id);
    }
}
