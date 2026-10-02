#ifndef RUSTDESK_VIDEO_COLOR_H
#define RUSTDESK_VIDEO_COLOR_H

#include <cstdint>
#include <vector>

// Values are also exposed through NAPI. A high-bit-depth SDR stream is NOT HDR.
enum class VideoDynamicRange { Unknown = 0, SDR = 1, PQ = 2, HLG = 3, Vivid = 4 };
enum class VideoColorOutput { Unknown = 0, SDR = 1, HDRSurface = 2, ToneMapped = 3,
                              SystemManaged = 4, Unsupported = 5 };

struct VideoColorInfo {
    int bitDepth = 0;
    int primaries = 2;
    int transfer = 2;
    int matrix = 2;
    int range = -1; // 0 limited, 1 full, -1 unspecified
    bool vivid = false;
    VideoColorOutput output = VideoColorOutput::Unknown;
    VideoDynamicRange dynamicRange() const;
    bool isHdr() const;
    bool operator==(const VideoColorInfo& other) const;
};

// Strides are BYTES (including high-bit-depth inputs); samples are LSB-aligned.
// Supports planar 4:2:0 / 4:2:2 / 4:4:4, 8 / 10 / 12 bit. Never clips HDR
// into 8 bit before transfer-function decoding and gamut conversion.
struct PlanarVideoImage {
    const uint8_t* planes[3] = {};
    int strides[3] = {};
    int width = 0;
    int height = 0;
    int chromaShiftX = 1;
    int chromaShiftY = 1;
    bool wideSamples = false;
    bool monochrome = false;
};

bool convertPlanarVideoToBGRA(const PlanarVideoImage& image, const VideoColorInfo& color,
                              std::vector<uint8_t>& output);
double hdrSignalToNits(double signal, int transfer);

#endif
