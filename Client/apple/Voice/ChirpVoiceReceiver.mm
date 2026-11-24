#import "ChirpVoiceReceiver.h"
#import <LiveKitWebRTC/RTCRtpReceiver.h>

#include <mutex>
#include "api/frame_transformer_interface.h"
#include "api/make_ref_counted.h"
#include "api/rtp_receiver_interface.h"

// The same accessor used by RTCFrameCryptor.mm in the pinned Apple framework.
@interface LKRTCRtpReceiver (ChirpNativeReceiver)
@property(nonatomic, readonly) webrtc::scoped_refptr<webrtc::RtpReceiverInterface> nativeRtpReceiver;
@end

namespace {
using OpenFrame = NSData * _Nullable (^)(NSData *);
using Callback = webrtc::scoped_refptr<webrtc::TransformedFrameCallback>;

class VoiceReceiver : public webrtc::FrameTransformerInterface {
 public:
  explicit VoiceReceiver(OpenFrame open) : open_([open copy]) {}

  void RegisterTransformedFrameCallback(Callback sink) override {
    std::lock_guard lock(mutex_);
    sink_ = std::move(sink);
  }

  void UnregisterTransformedFrameCallback() override {
    RegisterTransformedFrameCallback(nullptr);
  }

  void Transform(std::unique_ptr<webrtc::TransformableFrameInterface> frame) override {
    Callback sink;
    {
      std::lock_guard lock(mutex_);
      sink = sink_;
    }
    if (!sink || frame->GetDirection() != webrtc::TransformableFrameInterface::Direction::kReceiver)
      return;
    @autoreleasepool {
      const auto payload = frame->GetData();
      NSData *opened = open_([NSData dataWithBytes:payload.data() length:payload.size()]);
      if (!opened) return;
      frame->SetData({static_cast<const uint8_t *>(opened.bytes), opened.length});
      sink->OnTransformedFrame(std::move(frame));
    }
  }

 private:
  OpenFrame const open_;
  std::mutex mutex_;
  Callback sink_;
};
}  // namespace

BOOL ChirpInstallVoiceReceiver(LKRTCRtpReceiver *receiver, OpenFrame openFrame) {
  if (![receiver respondsToSelector:@selector(nativeRtpReceiver)]) return NO;
  auto native = receiver.nativeRtpReceiver;
  if (!native || native->media_type() != webrtc::MediaType::AUDIO) return NO;
  native->SetFrameTransformer(webrtc::make_ref_counted<VoiceReceiver>(openFrame));
  return YES;
}
