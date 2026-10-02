#ifndef RUSTDESK_VIDEO_COLOR_FORMAT_H
#define RUSTDESK_VIDEO_COLOR_FORMAT_H

#include "video_color.h"
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_buffer/native_buffer.h>

inline VideoColorInfo readVideoColorFormat(OH_AVFormat* format) {
    VideoColorInfo color;
    if (format == nullptr) return color;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_COLOR_PRIMARIES, &color.primaries);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_TRANSFER_CHARACTERISTICS, &color.transfer);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_MATRIX_COEFFICIENTS, &color.matrix);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_RANGE_FLAG, &color.range);
    int vivid = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_IS_HDR_VIVID, &vivid);
    color.vivid = vivid != 0;
    int pixelFormat = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &pixelFormat);
    if (pixelFormat == AV_PIXEL_FORMAT_RGBA1010102) color.bitDepth = 10;
    else if (pixelFormat == AV_PIXEL_FORMAT_YUVI420 || pixelFormat == AV_PIXEL_FORMAT_NV12 ||
             pixelFormat == AV_PIXEL_FORMAT_NV21 || pixelFormat == AV_PIXEL_FORMAT_RGBA) color.bitDepth = 8;
    // SURFACE_FORMAT is opaque. Main10 is a profile, not proof of actual buffer bit depth.
    return color;
}

inline void enrichVideoColorFromBuffer(OH_AVBuffer* buffer, VideoColorInfo& color) {
    if (!buffer) return;
    OH_NativeBuffer* native = OH_AVBuffer_GetNativeBuffer(buffer);
    if (!native) return;
    OH_NativeBuffer_Config config {};
    OH_NativeBuffer_GetConfig(native, &config);
    if (config.format == NATIVEBUFFER_PIXEL_FMT_YCBCR_P010 ||
        config.format == NATIVEBUFFER_PIXEL_FMT_YCRCB_P010 || config.format == NATIVEBUFFER_PIXEL_FMT_RGBA_1010102)
        color.bitDepth = 10;
    else if (config.format == NATIVEBUFFER_PIXEL_FMT_YCBCR_420_SP ||
             config.format == NATIVEBUFFER_PIXEL_FMT_YCRCB_420_SP ||
             config.format == NATIVEBUFFER_PIXEL_FMT_BGRA_8888 || config.format == NATIVEBUFFER_PIXEL_FMT_RGBA_8888)
        color.bitDepth = 8;
    // Some decoders expose CICP only on actual Surface buffers, not AVFormat.
    OH_NativeBuffer_ColorSpace space = OH_COLORSPACE_NONE;
    if (OH_NativeBuffer_GetColorSpace(native, &space) == 0) {
        if (space == OH_COLORSPACE_BT2020_PQ_FULL || space == OH_COLORSPACE_BT2020_PQ_LIMIT ||
            space == OH_COLORSPACE_DISPLAY_BT2020_PQ) {
            if (color.primaries == 2) color.primaries = 9;
            if (color.transfer == 0 || color.transfer == 2) color.transfer = 16;
            if (color.matrix == 2) color.matrix = 9;
            if (color.range < 0) color.range = space == OH_COLORSPACE_BT2020_PQ_LIMIT ? 0 : 1;
        } else if (space == OH_COLORSPACE_BT2020_HLG_FULL || space == OH_COLORSPACE_BT2020_HLG_LIMIT ||
                   space == OH_COLORSPACE_DISPLAY_BT2020_HLG) {
            if (color.primaries == 2) color.primaries = 9;
            if (color.transfer == 0 || color.transfer == 2) color.transfer = 18;
            if (color.matrix == 2) color.matrix = 9;
            if (color.range < 0) color.range = space == OH_COLORSPACE_BT2020_HLG_LIMIT ? 0 : 1;
        }
    }
    OH_NativeBuffer_Unreference(native); // GetNativeBuffer transfers one reference.
}

#endif
