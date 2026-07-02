#ifndef RUNNER_IMAGE_CODEC_H_
#define RUNNER_IMAGE_CODEC_H_

#include <cstdint>
#include <vector>

// WIC encode of BGRA8888 (premultiplied, sRGB) image data.
namespace codec {

// Encode to PNG. Returns empty on failure.
std::vector<uint8_t> EncodePng(const uint8_t* bgra, uint32_t width,
                               uint32_t height, uint32_t stride);

// Encode to JPEG. quality in [1,100]. Returns empty on failure.
std::vector<uint8_t> EncodeJpeg(const uint8_t* bgra, uint32_t width,
                                uint32_t height, uint32_t stride, int quality);

// Encode a tightly-packed RGBA16F (scRGB) buffer to JPEG XR (the Windows HDR
// screenshot format; 64bppRGBAHalf is JXR's canonical scRGB layout). stride in
// bytes (width * 8). [force_opaque] stamps alpha to 1.0 (the plain capture
// path); the HDR compositor passes false so a window-snap silhouette keeps its
// real alpha. Returns empty on failure.
std::vector<uint8_t> EncodeJxr(const uint8_t* rgba_f16, uint32_t width,
                               uint32_t height, uint32_t stride,
                               bool force_opaque = true);

}  // namespace codec

#endif  // RUNNER_IMAGE_CODEC_H_
