#include <jni.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "ChirpMLSNative.h"

JNIEXPORT jlong JNICALL Java_cn_youzifeile_chirp_media_MlsNative_open(
    JNIEnv *env, jobject self, jstring identity
) {
    const char *text = (*env)->GetStringUTFChars(env, identity, NULL);
    if (!text) return 0;
    ChirpMLSContext *context = chirp_mls_new(text);
    (*env)->ReleaseStringUTFChars(env, identity, text);
    return (jlong)(intptr_t)context;
}

JNIEXPORT void JNICALL Java_cn_youzifeile_chirp_media_MlsNative_close(
    JNIEnv *env, jobject self, jlong handle
) {
    chirp_mls_free((ChirpMLSContext *)(intptr_t)handle);
}

JNIEXPORT jbyteArray JNICALL Java_cn_youzifeile_chirp_media_MlsNative_request(
    JNIEnv *env, jobject self, jlong handle, jbyteArray request
) {
    jsize length = (*env)->GetArrayLength(env, request);
    if (length <= 0 || length > 262144) return NULL;
    char *text = calloc((size_t)length + 1, 1);
    if (!text) return NULL;
    (*env)->GetByteArrayRegion(env, request, 0, length, (jbyte *)text);
    char *response = (*env)->ExceptionCheck(env) || memchr(text, 0, length) ? NULL :
        chirp_mls_call((ChirpMLSContext *)(intptr_t)handle, text);
    for (jsize i = 0; i < length; i++) ((volatile char *)text)[i] = 0;
    free(text);
    if (!response) return NULL;
    jsize size = (jsize)strlen(response);
    jbyteArray result = (*env)->NewByteArray(env, size);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, size, (const jbyte *)response);
    chirp_mls_string_free(response);
    return result;
}

JNIEXPORT jbyteArray JNICALL Java_cn_youzifeile_chirp_media_MlsNative_senderKey(
    JNIEnv *env, jobject self, jlong handle, jstring identity, jboolean staged
) {
    const char *text = (*env)->GetStringUTFChars(env, identity, NULL);
    if (!text) return NULL;
    uint8_t key[32] = {0};
    int status = staged ? chirp_mls_staged_media_key((ChirpMLSContext *)(intptr_t)handle, text, key)
                        : chirp_mls_media_key((ChirpMLSContext *)(intptr_t)handle, text, key);
    (*env)->ReleaseStringUTFChars(env, identity, text);
    jbyteArray output = status == 0 ? (*env)->NewByteArray(env, sizeof key) : NULL;
    if (output) (*env)->SetByteArrayRegion(env, output, 0, sizeof key, (jbyte *)key);
    for (size_t index = 0; index < sizeof key; index++) ((volatile uint8_t *)key)[index] = 0;
    return output;
}
