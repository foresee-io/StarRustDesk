#include "voice_capture.h"
#include "rustdesk_ffi.h"
#include <ohaudio/native_audiostreambuilder.h>
#include <algorithm>

VoiceCapture& VoiceCapture::instance() { static VoiceCapture capture; return capture; }

int VoiceCapture::start() {
    std::lock_guard<std::mutex> lifecycle(lifecycle_);
    if (rust_voice_call_state() != 2) return -1;
    if (running_.load()) return 0;
    // stop() is called before every restart; never reuse an interrupted stream.
    if (capturer_ != nullptr) return -2;
    int error = OPUS_OK;
    encoder_ = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &error);
    if (!encoder_ || error != OPUS_OK) return -3;
    opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(32000));
    opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(5));
    samples_.clear();
    samples_.reserve(1920);
    OH_AudioStreamBuilder* builder = nullptr;
    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER);
    if (result == AUDIOSTREAM_SUCCESS && builder) {
        OH_AudioStreamBuilder_SetSamplingRate(builder, 48000);
        OH_AudioStreamBuilder_SetChannelCount(builder, 1);
        OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
        OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
        OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_VOICE_COMMUNICATION);
        OH_AudioCapturer_Callbacks callbacks{};
        callbacks.OH_AudioCapturer_OnReadData = read;
        callbacks.OH_AudioCapturer_OnInterruptEvent = interrupt;
        callbacks.OH_AudioCapturer_OnError = VoiceCapture::error;
        OH_AudioStreamBuilder_SetCapturerCallback(builder, callbacks, this);
        result = OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer_);
        OH_AudioStreamBuilder_Destroy(builder);
    }
    if (result == AUDIOSTREAM_SUCCESS && capturer_) {
        running_.store(true);
        result = OH_AudioCapturer_Start(capturer_);
        if (result == AUDIOSTREAM_SUCCESS) return 0;
    }
    running_.store(false);
    if (capturer_) { OH_AudioCapturer_Release(capturer_); capturer_ = nullptr; }
    opus_encoder_destroy(encoder_); encoder_ = nullptr;
    return -4;
}

void VoiceCapture::stop() {
    std::lock_guard<std::mutex> lifecycle(lifecycle_);
    running_.store(false);
    // Release joins callbacks. Never hold samplesMutex_ while stopping the stream.
    if (capturer_) {
        OH_AudioCapturer_Stop(capturer_);
        OH_AudioCapturer_Release(capturer_);
        capturer_ = nullptr;
    }
    std::lock_guard<std::mutex> samplesLock(samplesMutex_);
    if (encoder_) { opus_encoder_destroy(encoder_); encoder_ = nullptr; }
    std::fill(samples_.begin(), samples_.end(), 0);
    samples_.clear();
}

int32_t VoiceCapture::read(OH_AudioCapturer*, void* user, void* buffer, int32_t length) {
    auto* self = static_cast<VoiceCapture*>(user);
    if (!buffer || length <= 0 || length > 192000 || !self->running_.load() || rust_voice_call_state() != 2) return 0;
    std::lock_guard<std::mutex> lock(self->samplesMutex_);
    if (!self->encoder_ || !self->running_.load()) return 0;
    auto* input = static_cast<int16_t*>(buffer);
    int count = length / 2;
    // At most one 20 ms partial frame is retained. The Rust send queue is bounded.
    while (count > 0) {
        int take = std::min(count, 960 - static_cast<int>(self->samples_.size()));
        self->samples_.insert(self->samples_.end(), input, input + take);
        input += take; count -= take;
        if (self->samples_.size() == 960) {
            unsigned char packet[4000];
            int bytes = opus_encode(self->encoder_, self->samples_.data(), 960, packet, sizeof(packet));
            if (bytes > 0) rust_send_voice_frame(packet, bytes);
            std::fill(self->samples_.begin(), self->samples_.end(), 0);
            self->samples_.clear();
        }
    }
    return 0;
}

int32_t VoiceCapture::interrupt(OH_AudioCapturer*, void* user, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint hint) {
    if (hint == AUDIOSTREAM_INTERRUPT_HINT_RESUME || hint == AUDIOSTREAM_INTERRUPT_HINT_NONE) return 0;
    static_cast<VoiceCapture*>(user)->running_.store(false);
    rust_end_voice_call(); // UI lifecycle releases the capturer outside this callback.
    return 0;
}
int32_t VoiceCapture::error(OH_AudioCapturer*, void* user, OH_AudioStream_Result) {
    static_cast<VoiceCapture*>(user)->running_.store(false);
    rust_end_voice_call();
    return 0;
}
