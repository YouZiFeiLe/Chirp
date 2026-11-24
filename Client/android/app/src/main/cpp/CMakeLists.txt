cmake_minimum_required(VERSION 3.31)
project(chirp_mls LANGUAGES C CXX)

# Public frame encryptor/decryptor headers from webrtc-sdk/webrtc 7c1a802ab4 (M150).
add_library(chirp_voice SHARED voice_receiver.cpp)
target_include_directories(chirp_voice PRIVATE webrtc)
target_compile_features(chirp_voice PRIVATE cxx_std_20)
target_compile_options(chirp_voice PRIVATE -fno-rtti -fvisibility=hidden)

set(CHIRP_MLS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../apple/MLS/native")
get_filename_component(CHIRP_ROOT "${CHIRP_MLS_DIR}/../../../.." ABSOLUTE)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    # WebRTC 150.7871.08 calls FrameDecryptorInterface through relative vtables on arm64.
    target_compile_options(chirp_voice PRIVATE -fexperimental-relative-c++-abi-vtables)
    target_link_options(chirp_voice PRIVATE -fexperimental-relative-c++-abi-vtables)
    set(RUST_TARGET aarch64-linux-android)
    set(CLANG_TARGET aarch64-linux-android)
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(RUST_TARGET x86_64-linux-android)
    set(CLANG_TARGET x86_64-linux-android)
else()
    message(FATAL_ERROR "Unsupported Chirp MLS ABI: ${ANDROID_ABI}")
endif()

find_program(CARGO cargo HINTS "$ENV{HOME}/.cargo/bin" REQUIRED)
get_filename_component(CLANG_BIN "${CMAKE_C_COMPILER}" DIRECTORY)
string(TOUPPER "${RUST_TARGET}" RUST_ENV)
string(REPLACE "-" "_" RUST_ENV "${RUST_ENV}")
string(REPLACE "-" "_" CC_ENV "${RUST_TARGET}")
set(RUST_LIB "${CMAKE_CURRENT_BINARY_DIR}/cargo/${RUST_TARGET}/release/libchirp_mls_native.a")
file(GLOB_RECURSE RUST_SOURCES CONFIGURE_DEPENDS "${CHIRP_MLS_DIR}/src/*.rs")

add_custom_command(
    OUTPUT "${RUST_LIB}"
    COMMAND "${CMAKE_COMMAND}" -E env
        "CARGO_TARGET_${RUST_ENV}_LINKER=${CLANG_BIN}/${CLANG_TARGET}${ANDROID_PLATFORM_LEVEL}-clang"
        "CC_${CC_ENV}=${CLANG_BIN}/${CLANG_TARGET}${ANDROID_PLATFORM_LEVEL}-clang"
        "AR_${CC_ENV}=${CLANG_BIN}/llvm-ar"
        "${CARGO}" build --release --locked --target "${RUST_TARGET}"
        --manifest-path "${CHIRP_MLS_DIR}/Cargo.toml" --target-dir "${CMAKE_CURRENT_BINARY_DIR}/cargo"
    DEPENDS ${RUST_SOURCES} "${CHIRP_MLS_DIR}/Cargo.toml" "${CHIRP_MLS_DIR}/Cargo.lock"
        "${CHIRP_ROOT}/rust-toolchain.toml"
    VERBATIM
)
add_custom_target(chirp_openmls DEPENDS "${RUST_LIB}")
add_library(chirp_mls SHARED mls_jni.c)
add_dependencies(chirp_mls chirp_openmls)
target_include_directories(chirp_mls PRIVATE "${CHIRP_MLS_DIR}/include")
target_link_libraries(chirp_mls PRIVATE "${RUST_LIB}" log dl m)
target_link_options(chirp_mls PRIVATE "-Wl,--exclude-libs,ALL")

set(CHIRP_AUDIO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../apple/Audio/Sources/CChirpAudio")
set(RNNOISE_SOURCE "${CHIRP_RNNOISE_DIR}/Sources/CRNNoise")
set(RNNOISE_SOURCES denoise.c rnn.c pitch.c kiss_fft.c celt_lpc.c nnet.c nnet_default.c
    parse_lpcnet_weights.c rnnoise_data.c rnnoise_tables.c)
list(TRANSFORM RNNOISE_SOURCES PREPEND "${RNNOISE_SOURCE}/")
add_library(chirp_audio SHARED rnnoise_jni.c "${CHIRP_AUDIO_DIR}/ChirpRNNoise.c" ${RNNOISE_SOURCES})
target_include_directories(chirp_audio PRIVATE "${CHIRP_AUDIO_DIR}/include" "${RNNOISE_SOURCE}/include" "${RNNOISE_SOURCE}")
target_compile_definitions(chirp_audio PRIVATE RNNOISE_BUILD DISABLE_DEBUG_FLOAT=1)
target_compile_options(chirp_audio PRIVATE -O2 -fvisibility=hidden)
target_link_libraries(chirp_audio PRIVATE m)
