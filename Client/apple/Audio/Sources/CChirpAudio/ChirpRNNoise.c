#include "ChirpRNNoise.h"
#include "rnnoise.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { RN_RATE = 48000, RN_FRAME = 480, TAPS = 32, MAX_PHASES = 6, MAX_CHANNELS = 2 };

typedef struct {
    int input_rate, output_rate, phases, head;
    float coefficients[MAX_PHASES][TAPS];
    float history[TAPS];
} Resampler;

typedef struct {
    DenoiseState *state;
    Resampler up, down;
} Channel;

struct ChirpRNNoise {
    int rate, channels;
    bool failed;
    Channel channel[MAX_CHANNELS];
};

static int gcd(int a, int b) {
    while (b) { int remainder = a % b; a = b; b = remainder; }
    return a;
}

// A causal polyphase windowed-sinc FIR. Its history persists across 10 ms
// callbacks; the downsampler removes frequencies above the destination Nyquist.
static void resampler_init(Resampler *r, int input_rate, int output_rate) {
    r->input_rate = input_rate;
    r->output_rate = output_rate;
    r->phases = output_rate / gcd(input_rate, output_rate);
    const double pi = 3.14159265358979323846;
    const double cutoff = 0.45 * fmin(1.0, (double)output_rate / input_rate);
    for (int phase = 0; phase < r->phases; phase++) {
        double sum = 0;
        for (int k = 0; k < TAPS; k++) {
            double x = k + (double)phase / r->phases - (TAPS - 1) / 2.0;
            double sinc = fabs(x) < 1e-12 ? 2 * cutoff : sin(2 * pi * cutoff * x) / (pi * x);
            double window = 0.42 - 0.5 * cos(2 * pi * k / (TAPS - 1))
                           + 0.08 * cos(4 * pi * k / (TAPS - 1));
            r->coefficients[phase][k] = (float)(sinc * window);
            sum += sinc * window;
        }
        for (int k = 0; k < TAPS; k++) r->coefficients[phase][k] /= (float)sum;
    }
}

static void push(Resampler *r, float value) {
    r->history[r->head] = value;
    r->head = (r->head + 1) % TAPS;
}

static void resample(Resampler *r, const float *input, int input_count, float *output, int output_count) {
    int consumed = 0;
    for (int j = 0; j < output_count; j++) {
        int position = j * r->input_rate / r->output_rate;
        int phase = (j * r->input_rate % r->output_rate) * r->phases / r->output_rate;
        while (consumed <= position) push(r, input[consumed++]);
        float value = 0;
        for (int k = 0; k < TAPS; k++) {
            value += r->history[(r->head + TAPS - 1 - k) % TAPS] * r->coefficients[phase][k];
        }
        output[j] = value;
    }
    while (consumed < input_count) push(r, input[consumed++]);
}

ChirpRNNoise *chirp_rnnoise_create(int sample_rate, int channels) {
    if ((sample_rate != 8000 && sample_rate != 16000 && sample_rate != 32000 && sample_rate != RN_RATE)
        || channels < 1 || channels > MAX_CHANNELS || rnnoise_get_frame_size() != RN_FRAME) return NULL;
    ChirpRNNoise *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->rate = sample_rate;
    p->channels = channels;
    for (int i = 0; i < channels; i++) {
        // Unlike rnnoise_create(), explicitly check allocation before rnnoise_init().
        p->channel[i].state = calloc(1, (size_t)rnnoise_get_size());
        if (!p->channel[i].state || rnnoise_init(p->channel[i].state, NULL) != 0) {
            chirp_rnnoise_destroy(p);
            return NULL;
        }
        if (sample_rate != RN_RATE) {
            resampler_init(&p->channel[i].up, sample_rate, RN_RATE);
            resampler_init(&p->channel[i].down, RN_RATE, sample_rate);
        }
    }
    return p;
}

void chirp_rnnoise_destroy(ChirpRNNoise *p) {
    if (!p) return;
    for (int i = 0; i < p->channels; i++) rnnoise_destroy(p->channel[i].state);
    free(p);
}

bool chirp_rnnoise_process(ChirpRNNoise *p, float *samples, int frames, int channel) {
    if (!samples || frames <= 0) return false;
    if (!p || p->failed || frames != p->rate / 100 || channel < 0 || channel >= p->channels) goto failed;
    for (int i = 0; i < frames; i++) if (!isfinite(samples[i])) goto failed;

    Channel *c = &p->channel[channel];
    if (p->rate == RN_RATE) {
        rnnoise_process_frame(c->state, samples, samples);
    } else {
        float fullband[RN_FRAME];
        resample(&c->up, samples, frames, fullband, RN_FRAME);
        rnnoise_process_frame(c->state, fullband, fullband);
        resample(&c->down, fullband, RN_FRAME, samples, frames);
    }
    for (int i = 0; i < frames; i++) {
        if (!isfinite(samples[i])) goto failed;
        samples[i] = fmaxf(-32768.f, fminf(32767.f, samples[i]));
    }
    return true;

failed:
    if (p) p->failed = true;
    memset(samples, 0, (size_t)frames * sizeof(*samples));
    return false;
}
