#import <Foundation/Foundation.h>

@class LKRTCRtpReceiver;

NS_ASSUME_NONNULL_BEGIN

/// Installs the mandatory encoded-audio transform on this receiver. A nil
/// result from openFrame discards the frame before the jitter buffer/decoder.
FOUNDATION_EXPORT BOOL ChirpInstallVoiceReceiver(LKRTCRtpReceiver *receiver,
    NSData * _Nullable (^openFrame)(NSData *encryptedFrame));

NS_ASSUME_NONNULL_END
