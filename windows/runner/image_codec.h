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

}  // namespace codec

#endif  // RUNNER_IMAGE_CODEC_H_
