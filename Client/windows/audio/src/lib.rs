use sonora::config::{EchoCanceller, GainController2};
use sonora::{AudioProcessing, Config, StreamConfig};
use std::ptr;

const SAMPLES: usize = 480;

fn processor() -> AudioProcessing {
    AudioProcessing::builder()
        .config(Config {
            echo_canceller: Some(EchoCanceller::default()),
            gain_controller2: Some(GainController2::default()),
            ..Default::default()
        })
        .render_config(StreamConfig::new(48000, 1))
        .capture_config(StreamConfig::new(48000, 1))
        .build()
}

#[unsafe(no_mangle)]
pub extern "C" fn chirp_aec_new() -> *mut AudioProcessing {
    std::panic::catch_unwind(|| Box::into_raw(Box::new(processor()))).unwrap_or(ptr::null_mut())
}

/// The capture callback owns this processor. The two input buffers and one
/// independent output buffer each hold exactly 10 ms of mono PCM at 48 kHz.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chirp_aec_frame(
    state: *mut AudioProcessing,
    render: *const i16,
    microphone: *const i16,
    output: *mut i16,
    delay_ms: i32,
) -> bool {
    if state.is_null() || render.is_null() || microphone.is_null() || output.is_null() {
        return false;
    }
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        let apm = &mut *state;
        let render = std::slice::from_raw_parts(render, SAMPLES);
        let capture = std::slice::from_raw_parts(microphone, SAMPLES);
        let output = std::slice::from_raw_parts_mut(output, SAMPLES);
        apm.set_stream_delay_ms(delay_ms.clamp(0, 500)).is_ok()
            && apm.process_render_i16(render, &mut [0; SAMPLES]).is_ok()
            && apm.process_capture_i16(capture, output).is_ok()
    }))
    .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn chirp_aec_free(state: *mut AudioProcessing) {
    if !state.is_null() {
        drop(unsafe { Box::from_raw(state) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn processes_real_time_render_and_capture_frames() {
        let state = chirp_aec_new();
        assert!(!state.is_null());
        let mut result = [0; SAMPLES];
        let mut audible = false;
        for frame in 0..100 {
            let reference = [0; SAMPLES];
            let capture: [i16; SAMPLES] = std::array::from_fn(|i| {
                (5000.0 * (((i + frame * SAMPLES) as f64) * 0.07).sin()) as i16
            });
            assert!(unsafe {
                chirp_aec_frame(
                    state,
                    reference.as_ptr(),
                    capture.as_ptr(),
                    result.as_mut_ptr(),
                    60,
                )
            });
            audible |= result.iter().any(|v| v.unsigned_abs() > 250);
        }
        assert!(audible);
        unsafe { chirp_aec_free(state) };
    }
}
