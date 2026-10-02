#include "video_color.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

int main() {
    VideoColorInfo c;
    assert(!c.isHdr() && c.dynamicRange() == VideoDynamicRange::Unknown);
    c.transfer = 255; assert(c.dynamicRange() == VideoDynamicRange::Unknown);
    c.transfer = 3; assert(c.dynamicRange() == VideoDynamicRange::Unknown);
    c.bitDepth = 10; c.primaries = 9; c.transfer = 14;
    assert(!c.isHdr() && c.dynamicRange() == VideoDynamicRange::SDR);
    c.transfer = 16; assert(c.isHdr() && c.dynamicRange() == VideoDynamicRange::PQ);
    c.transfer = 18; assert(c.dynamicRange() == VideoDynamicRange::HLG);
    c.vivid = true; assert(c.dynamicRange() == VideoDynamicRange::Vivid);
    assert(std::abs(hdrSignalToNits(1, 16) - 10000) < 0.01);
    assert(std::abs(hdrSignalToNits(0.5080784215, 16) - 100) < 0.01);
    assert(std::abs(hdrSignalToNits(0.7518270962, 16) - 1000) < 0.01);
    assert(hdrSignalToNits(0, 16) == 0 && hdrSignalToNits(-1, 16) == 0);
    assert(std::abs(hdrSignalToNits(1, 18) - 1000) < 0.1);
    double last = 0;
    for (int tc : {16, 18}) {
        last = 0;
        for (int i = 0; i <= 1024; ++i) {
            const double nits = hdrSignalToNits(i / 1024.0, tc);
            assert(std::isfinite(nits) && nits >= last); last = nits;
        }
    }

    uint8_t y8[] = {16, 128, 235}, uv8[] = {128, 128, 128};
    PlanarVideoImage image;
    image.planes[0] = y8; image.planes[1] = uv8; image.planes[2] = uv8;
    image.strides[0] = image.strides[1] = image.strides[2] = 3;
    image.width = 3; image.height = 1; image.chromaShiftX = image.chromaShiftY = 0;
    c = {}; c.bitDepth = 8; c.transfer = 1; c.matrix = 1; c.range = 0;
    std::vector<uint8_t> output;
    assert(convertPlanarVideoToBGRA(image, c, output) && output.size() == 12);
    assert(output[0] == 0 && output[8] == 255);
    for (int i = 0; i < 3; ++i) assert(output[i*4] == output[i*4+1] && output[i*4+1] == output[i*4+2] && output[i*4+3] == 255);

    uint16_t y[4], uv[4];
    for (int bits : {10, 12}) {
        y[0] = 0; y[1] = 1 << (bits - 2); y[2] = 1 << (bits - 1); y[3] = (1 << bits) - 1;
        for (auto& value : uv) value = 1 << (bits - 1);
        image.width = 4; image.wideSamples = true;
        image.planes[0] = reinterpret_cast<uint8_t*>(y);
        image.planes[1] = image.planes[2] = reinterpret_cast<uint8_t*>(uv);
        image.strides[0] = image.strides[1] = image.strides[2] = 8;
        c.bitDepth = bits; c.range = 1; c.primaries = 9; c.matrix = 9;
        for (int tc : {16, 18}) {
            c.transfer = tc;
            assert(convertPlanarVideoToBGRA(image, c, output));
            assert(output[0] == 0 && output[12] >= 254);
            assert(output[0] < output[4] && output[4] < output[8] && output[8] < output[12]);
            // Tone mapping is not the old bit-shift/truncation operation.
            assert(output[8] != 128);
        }
        c.transfer = 14;
        assert(!c.isHdr() && convertPlanarVideoToBGRA(image, c, output));
        assert(output[8] >= 127 && output[8] <= 129);
    }

    c.matrix = 14; assert(!convertPlanarVideoToBGRA(image, c, output));
    c.matrix = 9; c.transfer = 16; c.primaries = 2;
    assert(!convertPlanarVideoToBGRA(image, c, output));
    c.primaries = 9; image.strides[0] = 2;
    assert(!convertPlanarVideoToBGRA(image, c, output));
    image.strides[0] = 8; image.planes[1] = nullptr;
    assert(!convertPlanarVideoToBGRA(image, c, output));
    image.monochrome = true;
    assert(convertPlanarVideoToBGRA(image, c, output));
    image.width = 20000; assert(!convertPlanarVideoToBGRA(image, c, output));

    // Odd-sized 4:2:0 frame including row padding.
    uint16_t oddY[12] = {}, oddUV[6] = {};
    image.width = image.height = 3; image.monochrome = false; image.wideSamples = true;
    image.chromaShiftX = image.chromaShiftY = 1;
    image.planes[0] = reinterpret_cast<uint8_t*>(oddY);
    image.planes[1] = image.planes[2] = reinterpret_cast<uint8_t*>(oddUV);
    image.strides[0] = 8; image.strides[1] = image.strides[2] = 6;
    assert(convertPlanarVideoToBGRA(image, c, output) && output.size() == 36);
    std::cout << "Native HDR/color tests passed (PQ, HLG, SDR, 8/10/12-bit, planes, invalid inputs)\n";
}
