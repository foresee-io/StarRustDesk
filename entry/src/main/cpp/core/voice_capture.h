#pragma once
#include <atomic>
#include <mutex>
#include <vector>
#include <opus.h>
#include <ohaudio/native_audiocapturer.h>

class VoiceCapture {
public:
    static VoiceCapture& instance();
    int start();
    void stop();
private:
    static int32_t read(OH_AudioCapturer*, void*, void*, int32_t);
    static int32_t interrupt(OH_AudioCapturer*, void*, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint);
    static int32_t error(OH_AudioCapturer*, void*, OH_AudioStream_Result);
    std::mutex lifecycle_;
    std::mutex samplesMutex_;
    std::atomic<bool> running_{false};
    OH_AudioCapturer* capturer_ = nullptr;
    OpusEncoder* encoder_ = nullptr;
    std::vector<int16_t> samples_;
};
