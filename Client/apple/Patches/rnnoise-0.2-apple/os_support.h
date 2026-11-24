// RNNoise v0.2's ARM NEON/scalar headers reference this missing Opus header.
// They only require OPUS_CLEAR; use RNNoise's existing equivalent operation.
#ifndef CHIRP_RNNOISE_OS_SUPPORT_H
#define CHIRP_RNNOISE_OS_SUPPORT_H
#include "common.h"
#define OPUS_CLEAR(dst, count) RNN_CLEAR(dst, count)
#endif
