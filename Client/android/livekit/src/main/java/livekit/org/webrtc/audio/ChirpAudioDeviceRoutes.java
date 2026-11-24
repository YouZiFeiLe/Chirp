package livekit.org.webrtc.audio;

import android.media.AudioDeviceInfo;

/** Null resets Android AudioRecord to the system route. The upstream public
 * wrapper dereferences null while logging, before calling this null-safe API. */
public final class ChirpAudioDeviceRoutes {
    private ChirpAudioDeviceRoutes() {}

    public static void setInput(JavaAudioDeviceModule module, AudioDeviceInfo device) {
        module.audioInput.setPreferredDevice(device);
    }
}
