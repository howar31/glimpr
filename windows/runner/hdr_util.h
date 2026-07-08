#ifndef RUNNER_HDR_UTIL_H_
#define RUNNER_HDR_UTIL_H_

#include <windows.h>

#include <cstdint>
#include <vector>

// HDR display detection + the shared scRGB(fp16) -> sRGB(8-bit) tone-map used
// by every SDR consumer of an HDR-monitor capture (direct screenshots, the
// freeze overlay, the loupe live feed, SDR recording, GIF). The GPU compute
// shader in hdr_convert_gpu.* implements the SAME math for the continuous
// recording path; keep the two in sync.
//
// Colour model: WGC fp16 frames are scRGB -- linear light, BT.709 primaries,
// 1.0 == 80 nits. SDR-in-HDR content sits at the user's SDR white level (a
// display setting, in nits), so dividing by (sdr_white_nits / 80) lands SDR
// content EXACTLY on [0,1]; genuine HDR highlights land above 1 and clip to
// white, which is the faithful SDR rendition (this is the wash-out fix: the
// OS 8-bit conversion path does not honour the SDR white level).
namespace hdr {

struct MonitorHdrInfo {
  bool hdr = false;
  float sdr_white_nits = 240.0f;  // Windows default SDR brightness slider
  float max_nits = 1000.0f;       // panel peak (HDR10 metadata hint)
};

// Whether |monitor| is currently in HDR mode (advanced colour, PQ colour
// space) + its SDR white level and peak luminance. Tolerates zero visible
// DXGI outputs (SSH session 0) by returning a default non-HDR info.
MonitorHdrInfo QueryMonitorHdr(HMONITOR monitor);

// A Dart bool setting, read straight from the shared_preferences JSON
// (%APPDATA%\Howar31\Glimpr\shared_preferences.json) -- for native code
// that must decide before any Dart runs (HDR-base retention) or without a
// channel (the pin windows). [dflt] when the file/key is missing.
bool ReadPrefsBool(const char* key_name, bool dflt);

// ReadPrefsBool("hdr_screenshot", false): the native freeze's HDR-base
// retention decision.
bool ReadHdrScreenshotSetting();

// Scalar half <-> float (the HDR compositor works in float).
float HalfToFloatScalar(uint16_t h);
uint16_t FloatToHalfScalar(float f);

// Extended sRGB transfer curve (defined for values above 1.0 too). The HDR
// compositor blends/filters in this GAMMA domain, relative to SDR white, so
// every result matches the Dart (sRGB) composite exactly wherever the base is
// within SDR range.
float ExtSrgbEncode(float linear);
float ExtSrgbDecode(float encoded);

// Half-float bit pattern -> tone-mapped 8-bit value table. Built once per SDR
// white level (65536 pow() entries, ~1 ms); mapping is then 3 lookups/pixel.
class ToneMapLut {
 public:
  // Builds (or rebuilds) for |sdr_white_nits|; no-op when already built for
  // the same value.
  void Build(float sdr_white_nits);
  bool built() const { return !lut_.empty(); }

  // Tightly-packed RGBA16F -> BGRA8888 (alpha forced opaque).
  void MapToBgra(const uint16_t* rgba_f16, size_t px_count,
                 uint8_t* out_bgra) const;
  // Tightly-packed RGBA16F -> RGBA8888 (alpha forced opaque; the loupe patch
  // byte order).
  void MapToRgba(const uint16_t* rgba_f16, size_t px_count,
                 uint8_t* out_rgba) const;

 private:
  float built_for_ = -1.0f;
  std::vector<uint8_t> lut_;  // 65536: half bits -> 8-bit sRGB
};

}  // namespace hdr

#endif  // RUNNER_HDR_UTIL_H_
