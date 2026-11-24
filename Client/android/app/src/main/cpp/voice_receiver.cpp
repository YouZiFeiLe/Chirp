#include <atomic>
#include <cstring>
#include <jni.h>
#include "api/crypto/frame_decryptor_interface.h"
#include "api/crypto/frame_encryptor_interface.h"

namespace {
class Environment {
 public:
  explicit Environment(JavaVM* vm) : vm_(vm) {
    if (vm_->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_EDETACHED)
      attached_ = vm_->AttachCurrentThread(&env, nullptr) == JNI_OK;
  }
  ~Environment() { if (attached_) vm_->DetachCurrentThread(); }
  JNIEnv* env = nullptr;

 private:
  JavaVM* vm_;
  bool attached_ = false;
};

template <typename Interface>
class JavaCallback : public Interface {
 public:
  JavaCallback(JavaVM* vm, jobject target, jmethodID method) : vm_(vm), target_(target), method_(method) {}
  ~JavaCallback() override {
    Environment thread(vm_);
    if (thread.env) thread.env->DeleteGlobalRef(target_);
  }
  void AddRef() const override { refs_.fetch_add(1, std::memory_order_relaxed); }
  webrtc::RefCountReleaseStatus Release() const override {
    if (refs_.fetch_sub(1, std::memory_order_acq_rel) != 1)
      return webrtc::RefCountReleaseStatus::kOtherRefsRemained;
    delete this;
    return webrtc::RefCountReleaseStatus::kDroppedLastRef;
  }

 protected:
  JavaVM* const vm_;
  jobject const target_;
  jmethodID const method_;

 private:
  mutable std::atomic<int> refs_{1}; // The installing Java caller holds this reference.
};

jbyteArray CopyFrame(JNIEnv* env, std::span<const uint8_t> frame) {
  auto input = env->NewByteArray(static_cast<jsize>(frame.size()));
  if (input) env->SetByteArrayRegion(input, 0, static_cast<jsize>(frame.size()),
                                     reinterpret_cast<const jbyte*>(frame.data()));
  return input;
}

class Receiver final : public JavaCallback<webrtc::FrameDecryptorInterface> {
 public:
  using JavaCallback::JavaCallback;
  size_t GetMaxPlaintextByteSize(webrtc::MediaType, size_t size) override { return size; }

  Result Decrypt(webrtc::MediaType type, const std::vector<uint32_t>&,
                 std::span<const uint8_t>, std::span<const uint8_t> encrypted,
                 std::span<uint8_t> output) override {
    Result rejected(Status::kFailedToDecrypt, 0);
    if (type != webrtc::MediaType::AUDIO || encrypted.size() < 31 || encrypted.size() > 65535) return rejected;
    Environment thread(vm_);
    JNIEnv* env = thread.env;
    if (!env || env->PushLocalFrame(4) != JNI_OK) return rejected;
    auto input = CopyFrame(env, encrypted);
    jsize size = 0;
    if (input && !env->ExceptionCheck()) {
      auto clear = static_cast<jbyteArray>(env->CallObjectMethod(target_, method_, input));
      if (clear && !env->ExceptionCheck()) {
        const auto len = env->GetArrayLength(clear);
        if (len > 0 && static_cast<size_t>(len) <= output.size()) {
          env->GetByteArrayRegion(clear, 0, len, reinterpret_cast<jbyte*>(output.data()));
          if (!env->ExceptionCheck()) size = len;
        }
      }
    }
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->PopLocalFrame(nullptr);
    return size > 0 ? Result(Status::kOk, size) : rejected;
  }

};

class Sender final : public JavaCallback<webrtc::FrameEncryptorInterface> {
 public:
  using JavaCallback::JavaCallback;
  size_t GetMaxCiphertextByteSize(webrtc::MediaType, size_t size) override { return size; }

  int Encrypt(webrtc::MediaType type, uint32_t ssrc, std::span<const uint8_t>,
              std::span<const uint8_t> frame, std::span<uint8_t> output, size_t* written) override {
    *written = 0;
    if (type != webrtc::MediaType::AUDIO || frame.size() < 31 || frame.size() > 65535 ||
        output.size() < frame.size()) return -1;
    Environment thread(vm_);
    JNIEnv* env = thread.env;
    if (!env || env->PushLocalFrame(1) != JNI_OK) return -1;
    auto input = CopyFrame(env, frame);
    bool accepted = input && !env->ExceptionCheck() &&
        env->CallBooleanMethod(target_, method_, static_cast<jint>(ssrc), input) == JNI_TRUE;
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      accepted = false;
    }
    env->PopLocalFrame(nullptr);
    if (!accepted) return -1;
    std::memcpy(output.data(), frame.data(), frame.size());
    *written = frame.size();
    return 0;
  }
};

template <typename Callback>
jlong Create(JNIEnv* env, jobject self, const char* name, const char* signature) {
  JavaVM* vm = nullptr;
  if (env->GetJavaVM(&vm) != JNI_OK) return 0;
  jmethodID method = env->GetMethodID(env->GetObjectClass(self), name, signature);
  if (!method) return 0;
  jobject ref = env->NewGlobalRef(self);
  return ref ? reinterpret_cast<jlong>(new Callback(vm, ref, method)) : 0;
}
}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_cn_youzifeile_chirp_media_VoiceReceiver_create(JNIEnv* env, jobject self) {
  return Create<Receiver>(env, self, "open", "([B)[B");
}

extern "C" JNIEXPORT void JNICALL
Java_cn_youzifeile_chirp_media_VoiceReceiver_release(JNIEnv*, jobject, jlong handle) {
  reinterpret_cast<Receiver*>(handle)->Release();
}

extern "C" JNIEXPORT jlong JNICALL
Java_cn_youzifeile_chirp_media_VoiceSender_create(JNIEnv* env, jobject self) {
  return Create<Sender>(env, self, "accepts", "(I[B)Z");
}

extern "C" JNIEXPORT void JNICALL
Java_cn_youzifeile_chirp_media_VoiceSender_release(JNIEnv*, jobject, jlong handle) {
  reinterpret_cast<Sender*>(handle)->Release();
}
