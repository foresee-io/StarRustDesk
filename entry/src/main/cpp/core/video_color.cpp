#include "video_color.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

namespace {
template <typename T> T bounded(T value, T low, T high) { return std::max(low, std::min(value, high)); }
}

VideoDynamicRange VideoColorInfo::dynamicRange() const {
    if (vivid) return VideoDynamicRange::Vivid;
    if (transfer == 16) return VideoDynamicRange::PQ; // SMPTE ST 2084
    if (transfer == 18) return VideoDynamicRange::HLG; // ARIB STD-B67
    if (transfer == 1 || (transfer >= 4 && transfer <= 15) || transfer == 17) return VideoDynamicRange::SDR;
    return VideoDynamicRange::Unknown;
}

bool VideoColorInfo::isHdr() const {
    const auto type = dynamicRange();
    return type == VideoDynamicRange::PQ || type == VideoDynamicRange::HLG || type == VideoDynamicRange::Vivid;
}

bool VideoColorInfo::operator==(const VideoColorInfo& other) const {
    return bitDepth == other.bitDepth && primaries == other.primaries && transfer == other.transfer &&
        matrix == other.matrix && range == other.range && vivid == other.vivid && output == other.output;
}

double hdrSignalToNits(double signal, int transfer) {
    signal = bounded(signal, 0.0, 1.0);
    if (transfer == 16) {
        constexpr double m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0;
        constexpr double c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
        const double p = std::pow(signal, 1.0 / m2);
        return 10000.0 * std::pow(std::max(p - c1, 0.0) / std::max(c2 - c3 * p, 1e-9), 1.0 / m1);
    }
    if (transfer == 18) {
        constexpr double a = 0.17883277, b = 0.28466892, c = 0.55991073;
        // Nominal 1000-nit HLG display with system gamma 1.2.
        const double scene = signal <= 0.5 ? signal * signal / 3.0 : (std::exp((signal - c) / a) + b) / 12.0;
        return 1000.0 * std::pow(scene, 1.2);
    }
    return 0.0;
}

namespace {
const std::array<float, 4096>& hdrLut(int transfer) {
    static const auto pq = [] { std::array<float, 4096> values {};
        for (size_t i = 0; i < values.size(); ++i) values[i] = hdrSignalToNits(i / 4095.0, 16);
        return values; }();
    static const auto hlg = [] { std::array<float, 4096> values {};
        // HLG inverse OETF only; the luminance-dependent OOTF below uses one
        // shared gain for RGB, not independent channel gamma (which shifts hue).
        for (size_t i = 0; i < values.size(); ++i)
            values[i] = 1000.0 * std::pow(hdrSignalToNits(i / 4095.0, 18) / 1000.0, 1.0 / 1.2);
        return values; }();
    return transfer == 16 ? pq : hlg;
}

float linearToSrgb(float value) {
    value = bounded(value, 0.0f, 1.0f);
    // LUT keeps expensive power functions off the per-pixel hot path.
    static const auto lut = [] { std::array<float, 4096> values {};
        for (size_t i = 0; i < values.size(); ++i) {
            const double v = i / 4095.0;
            values[i] = v <= 0.0031308 ? 12.92 * v : 1.055 * std::pow(v, 1.0 / 2.4) - 0.055;
        }
        return values; }();
    return lut[static_cast<size_t>(value * 4095.0f + 0.5f)];
}

float hlgSystemGain(float luminance) {
    static const auto lut = [] { std::array<float, 4096> values {};
        for (size_t i = 0; i < values.size(); ++i) values[i] = std::pow(i / 4095.0, 0.2);
        return values; }();
    const float index = bounded(luminance, 0.0f, 1.0f) * 4095.0f;
    const size_t low = static_cast<size_t>(index), high = std::min(low + 1, lut.size() - 1);
    return lut[low] + (lut[high] - lut[low]) * (index - low);
}

int sample(const uint8_t* row, int x, bool wide) {
    if (!wide) return row[x];
    uint16_t value;
    std::memcpy(&value, row + x * 2, sizeof(value));
    return value;
}

uint8_t byte(float value) { return static_cast<uint8_t>(bounded(value, 0.0f, 1.0f) * 255.0f + 0.5f); }
}

bool convertPlanarVideoToBGRA(const PlanarVideoImage& image, const VideoColorInfo& color,
                              std::vector<uint8_t>& output) {
    const int bits = color.bitDepth;
    if (image.width <= 0 || image.height <= 0 || image.width > 16384 || image.height > 16384 ||
        static_cast<uint64_t>(image.width) * image.height > 64 * 1024 * 1024 ||
        (bits != 8 && bits != 10 && bits != 12) || (bits > 8 && !image.wideSamples) ||
        image.chromaShiftX < 0 || image.chromaShiftX > 1 || image.chromaShiftY < 0 || image.chromaShiftY > 1 ||
        image.planes[0] == nullptr || (!image.monochrome && (!image.planes[1] || !image.planes[2]))) return false;
    const int bytes = image.wideSamples ? 2 : 1;
    const int chromaWidth = (image.width + (1 << image.chromaShiftX) - 1) >> image.chromaShiftX;
    if (image.strides[0] < image.width * bytes || (!image.monochrome &&
        (image.strides[1] < chromaWidth * bytes || image.strides[2] < chromaWidth * bytes))) return false;
    // BT.2020 constant-luminance and ICtCp require different transforms.
    if (color.matrix == 10 || color.matrix == 14 || (color.vivid && color.transfer != 16 && color.transfer != 18))
        return false;
    const bool hdr = color.isHdr();
    if (hdr && color.primaries != 9 && color.primaries != 1) return false;
    const float maximum = static_cast<float>((1 << bits) - 1), scale = static_cast<float>(1 << (bits - 8));
    const bool full = color.range == 1;
    const float yOffset = full ? 0.0f : 16.0f * scale, yRange = full ? maximum : 219.0f * scale;
    const float cCenter = static_cast<float>(1 << (bits - 1)), cRange = full ? maximum : 224.0f * scale;
    const float kr = color.matrix == 9 ? 0.2627f : color.matrix == 1 ? 0.2126f : 0.299f;
    const float kb = color.matrix == 9 ? 0.0593f : color.matrix == 1 ? 0.0722f : 0.114f;
    const float kg = 1.0f - kr - kb;
    output.resize(static_cast<size_t>(image.width) * image.height * 4);
    const std::array<float, 4096>* lut = hdr ? &hdrLut(color.transfer) : nullptr;
    for (int y = 0; y < image.height; ++y) {
        const uint8_t* yRow = image.planes[0] + static_cast<size_t>(y) * image.strides[0];
        const uint8_t* uRow = image.monochrome ? nullptr : image.planes[1] +
            static_cast<size_t>(y >> image.chromaShiftY) * image.strides[1];
        const uint8_t* vRow = image.monochrome ? nullptr : image.planes[2] +
            static_cast<size_t>(y >> image.chromaShiftY) * image.strides[2];
        for (int x = 0; x < image.width; ++x) {
            const int cx = x >> image.chromaShiftX;
            const float sy = static_cast<float>(sample(yRow, x, image.wideSamples));
            const float su = uRow ? static_cast<float>(sample(uRow, cx, image.wideSamples)) : cCenter;
            const float sv = vRow ? static_cast<float>(sample(vRow, cx, image.wideSamples)) : cCenter;
            float r, g, b;
            if (color.matrix == 0 && !image.monochrome) { // AV1 identity matrix (planes G/B/R)
                r = sv / maximum; g = sy / maximum; b = su / maximum;
            } else {
                const float luma = (sy - yOffset) / yRange, u = (su - cCenter) / cRange, v = (sv - cCenter) / cRange;
                r = luma + 2.0f * (1.0f - kr) * v;
                b = luma + 2.0f * (1.0f - kb) * u;
                g = luma - 2.0f * kb * (1.0f - kb) / kg * u - 2.0f * kr * (1.0f - kr) / kg * v;
            }
            if (hdr) {
                r = (*lut)[static_cast<size_t>(bounded(r, 0.0f, 1.0f) * 4095.0f + 0.5f)] / 203.0f;
                g = (*lut)[static_cast<size_t>(bounded(g, 0.0f, 1.0f) * 4095.0f + 0.5f)] / 203.0f;
                b = (*lut)[static_cast<size_t>(bounded(b, 0.0f, 1.0f) * 4095.0f + 0.5f)] / 203.0f;
                if (color.transfer == 18) {
                    const float gain = hlgSystemGain((0.2627f * r + 0.6780f * g + 0.0593f * b) * 203.0f / 1000.0f);
                    r *= gain; g *= gain; b *= gain;
                }
                if (color.primaries == 9) {
                    const float nr = 1.660491f * r - 0.587641f * g - 0.072850f * b;
                    const float ng = -0.124550f * r + 1.132900f * g - 0.008349f * b;
                    const float nb = -0.018151f * r - 0.100579f * g + 1.118730f * b;
                    r = nr; g = ng; b = nb;
                }
                const float luma = std::max(0.0f, 0.2126f * r + 0.7152f * g + 0.0722f * b);
                const float peak = (color.transfer == 16 ? 10000.0f : 1000.0f) / 203.0f;
                // Luminance-preserving extended Reinhard; no per-channel hard clipping before mapping.
                const float factor = (1.0f + luma / (peak * peak)) / (1.0f + luma);
                r = linearToSrgb(r * factor); g = linearToSrgb(g * factor); b = linearToSrgb(b * factor);
            }
            uint8_t* pixel = output.data() + (static_cast<size_t>(y) * image.width + x) * 4;
            pixel[0] = byte(b); pixel[1] = byte(g); pixel[2] = byte(r); pixel[3] = 255;
        }
    }
    return true;
}
