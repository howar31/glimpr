#ifndef RUNNER_CLIPBOARD_DIB_H_
#define RUNNER_CLIPBOARD_DIB_H_

#include <cstdint>
#include <cstring>

// Packed CF_DIB payload building for FULLY OPAQUE images, header-only so the
// native test target can exercise it. Alpha-aware clipboard consumers (LINE
// et al) matte or halo an image whose clipboard advertises an alpha channel;
// Windows' own screenshot clipboard (CF_BITMAP with synthesized DIB/DIBV5,
// alpha mask zero) never triggers that path. Mirroring it means writing a
// classic bottom-up 32bpp BI_BITFIELDS BITMAPINFOHEADER DIB -- the system
// synthesizes CF_DIBV5 (alpha mask 0) and CF_BITMAP from it -- and no PNG
// clipboard format.
namespace clipdib {

// True when every pixel's alpha is 255. [stride] in bytes; rows are BGRA.
inline bool AllOpaque(const uint8_t* bgra, uint32_t w, uint32_t h,
                      uint32_t stride) {
  for (uint32_t y = 0; y < h; ++y) {
    const uint8_t* row = bgra + static_cast<size_t>(y) * stride;
    for (uint32_t x = 0; x < w; ++x) {
      if (row[x * 4 + 3] != 0xFF) return false;
    }
  }
  return true;
}

// BITMAPINFOHEADER (40) + the three BI_BITFIELDS channel masks (12).
constexpr size_t kOpaqueDibHeaderSize = 52;

inline size_t OpaqueDibSize(uint32_t w, uint32_t h) {
  return kOpaqueDibHeaderSize + static_cast<size_t>(w) * 4 * h;
}

// Write the packed DIB into [dst] (>= OpaqueDibSize(w, h) bytes): header,
// R/G/B masks, then the pixel rows bottom-up as CF_DIB consumers expect.
inline void WriteOpaqueDib(uint8_t* dst, const uint8_t* bgra, uint32_t w,
                           uint32_t h, uint32_t stride) {
  const uint32_t row = w * 4;
  auto put32 = [dst](size_t off, uint32_t v) { std::memcpy(dst + off, &v, 4); };
  auto put16 = [dst](size_t off, uint16_t v) { std::memcpy(dst + off, &v, 2); };
  std::memset(dst, 0, kOpaqueDibHeaderSize);
  put32(0, 40);        // biSize (BITMAPINFOHEADER)
  put32(4, w);         // biWidth
  put32(8, h);         // biHeight, positive: bottom-up
  put16(12, 1);        // biPlanes
  put16(14, 32);       // biBitCount
  put32(16, 3);        // biCompression = BI_BITFIELDS
  put32(20, row * h);  // biSizeImage
  put32(40, 0x00FF0000u);
  put32(44, 0x0000FF00u);
  put32(48, 0x000000FFu);
  uint8_t* pix = dst + kOpaqueDibHeaderSize;
  for (uint32_t y = 0; y < h; ++y) {
    std::memcpy(pix + static_cast<size_t>(h - 1 - y) * row,
                bgra + static_cast<size_t>(y) * stride, row);
  }
}

}  // namespace clipdib

#endif  // RUNNER_CLIPBOARD_DIB_H_
