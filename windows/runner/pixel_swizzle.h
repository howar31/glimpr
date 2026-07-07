#ifndef RUNNER_PIXEL_SWIZZLE_H_
#define RUNNER_PIXEL_SWIZZLE_H_

#include <cstdint>
#include <utility>
#include <vector>

// The editor composites in RGBA8888 (dart:ui rawRgba); the native codec +
// decoration take BGRA. Swap R<->B (G, A unchanged); alpha sense is preserved.
// Header-only so the encode channel and its tests share one definition.
namespace pixfmt {

inline std::vector<uint8_t> RgbaToBgra(const std::vector<uint8_t>& rgba) {
  std::vector<uint8_t> bgra = rgba;
  for (size_t i = 0; i + 3 < bgra.size(); i += 4) {
    std::swap(bgra[i], bgra[i + 2]);
  }
  return bgra;
}

}  // namespace pixfmt

#endif  // RUNNER_PIXEL_SWIZZLE_H_
