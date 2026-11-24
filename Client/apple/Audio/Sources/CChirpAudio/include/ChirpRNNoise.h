#ifndef CHIRP_RNNOISE_H
#define CHIRP_RNNOISE_H

#include <stdbool.h>

typedef struct ChirpRNNoise ChirpRNNoise;

// One instance belongs to one capture stream. All calls must be serialized.
ChirpRNNoise *chirp_rnnoise_create(int sample_rate, int channels);
void chirp_rnnoise_destroy(ChirpRNNoise *processor);

// Exactly 10 ms of planar Float-S16 samples, modified in place. No allocation,
// locks, I/O, or raw-audio fallback on the processing path. Invalid input is silenced.
bool chirp_rnnoise_process(ChirpRNNoise *processor, float *samples, int frames, int channel);

#endif
