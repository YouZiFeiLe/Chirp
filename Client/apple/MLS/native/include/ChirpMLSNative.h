#ifndef CHIRP_MLS_NATIVE_H
#define CHIRP_MLS_NATIVE_H
#include <stddef.h>
#include <stdint.h>

typedef struct ChirpMLSContext ChirpMLSContext;
ChirpMLSContext *chirp_mls_new(const char *identity);
void chirp_mls_free(ChirpMLSContext *context);
// RPC responses contain only public protocol material, signatures, or errors.
char *chirp_mls_call(ChirpMLSContext *context, const char *request);
void chirp_mls_string_free(char *value);
// Copies one sender key directly into a caller-owned 32-byte buffer, never JSON.
int32_t chirp_mls_media_key(ChirpMLSContext *context, const char *identity, uint8_t *output);
int32_t chirp_mls_staged_media_key(ChirpMLSContext *context, const char *identity, uint8_t *output);
#endif
