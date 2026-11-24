#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "ChirpRNNoise.h"

typedef struct {
    ChirpRNNoise *denoiser;
    int frames;
} Capture;

JNIEXPORT jlong JNICALL
Java_cn_youzifeile_chirp_media_RNNoiseProcessor_create(JNIEnv *env, jobject self, jint rate, jint channels) {
    (void)env; (void)self;
    // WebRTC's Android external processor exposes the first mono channel as
    // contiguous Float-S16 samples. Refuse unsupported layouts rather than
    // leaving an additional channel unprocessed.
    if (channels != 1) return 0;
    Capture *capture = calloc(1, sizeof(*capture));
    if (!capture) return 0;
    capture->denoiser = chirp_rnnoise_create(rate, channels);
    if (!capture->denoiser) { free(capture); return 0; }
    capture->frames = rate / 100;
    return (jlong)(intptr_t)capture;
}

JNIEXPORT jboolean JNICALL
Java_cn_youzifeile_chirp_media_RNNoiseProcessor_process(JNIEnv *env, jobject self, jlong handle, jobject buffer, jint frames) {
    (void)self;
    Capture *capture = (Capture *)(intptr_t)handle;
    float *samples = (*env)->GetDirectBufferAddress(env, buffer);
    jlong capacity = (*env)->GetDirectBufferCapacity(env, buffer);
    if (!capture || !samples || frames != capture->frames || capacity < (jlong)frames * sizeof(float)) {
        if (samples && capacity > 0) memset(samples, 0, (size_t)capacity);
        return JNI_FALSE;
    }
    return chirp_rnnoise_process(capture->denoiser, samples, frames, 0) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_cn_youzifeile_chirp_media_RNNoiseProcessor_destroy(JNIEnv *env, jobject self, jlong handle) {
    (void)env; (void)self;
    Capture *capture = (Capture *)(intptr_t)handle;
    if (!capture) return;
    chirp_rnnoise_destroy(capture->denoiser);
    free(capture);
}
