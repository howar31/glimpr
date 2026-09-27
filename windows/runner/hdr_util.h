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
// content EXACTLY on [0,1] (this is the wash-out fix: the OS 8-bit conversion
// path does not honour the SDR white level).
//
// Content ABOVE SDR white (HDR video, Auto HDR / HDR games, whose whole
// picture scales with the panel's peak luminance) cannot be clipped: a
// full-screen game in a 1000-nit mode sits almost entirely above SDR white
// and would blow out to white. The one-shot capture paths therefore measure
// the frame first (MeasureExposure) and tone-map with two frame-adaptive
// terms (ToneMapCurve):
//   exposure  -- when HDR content is the BULK of the frame, its bright
//                percentile becomes the white point (the picture is exposed
//                the way the eye adapts to it on the display);
//   shoulder  -- whatever still lands above the knee is rolled off smoothly
//                to the frame's peak instead of being clipped. The shoulder
//                is applied to max(R,G,B) and the three channels are scaled
//                by the same factor, so a bright saturated colour keeps its
//                hue and saturation instead of drifting to white (which is
//                what a per-channel roll-off or clip does).
// A frame with nothing above SDR white gets the exact legacy mapping, byte
// for byte, so desktop screenshots on an HDR display are unchanged. The
// continuous paths (recording, live loupe) still use the default exposure
// (== clip) until they get a temporally smoothed measurement.
namespace hdr {

struct MonitorHdrInfo {
  bool hdr = false;
  float sdr_white_nits = 240.0f;  // Windows default SDR brightness slider
  float max_nits = 1000.0f;       // panel peak (HDR10 metadata hint)
  // Raw DXGI_OUTPUT_DESC1 facts for the diagnostics snapshot (-1 = unknown).
  int color_space = -1;
  int bits_per_color = -1;
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

// Frame-adaptive tone-map terms, both relative to SDR white (1.0 == the SDR
// white level). The defaults reproduce the legacy clip exactly.
struct ToneMapExposure {
  // Exposure white point: the frame is divided by this before the curve.
  // >= 1; 1 leaves SDR content exact.
  float white = 1.0f;
  // Highlight peak AFTER exposure. > 1 enables the shoulder, which rolls
  // [kToneMapKnee, peak] off into [kToneMapKnee, 1]; 1 (or less) == clip.
  float peak = 1.0f;
};

// Where the shoulder starts (linear, relative to the exposed white).
constexpr float kToneMapKnee = 0.85f;

// The pure curve: |rel| = linear value relative to SDR white -> linear
// [0,1]. Identity below the knee when peak > 1, exact clip when peak <= 1.
float ToneMapCurve(float rel, const ToneMapExposure& exposure);

// Scans a tightly-packed RGBA16F frame (subsampled; a 4K frame costs well
// under a millisecond) and derives the exposure terms: the bright percentile
// of max(R,G,B) becomes the white point in proportion to how much of the
// frame sits above SDR white (a full-screen HDR game exposes fully, a small
// HDR window on a desktop barely moves it), capped at the panel peak; the
// top-percentile peak feeds the shoulder. Negative / NaN texels count as 0.
ToneMapExposure MeasureExposure(const uint16_t* rgba_f16, uint32_t width,
                                uint32_t height, float sdr_white_nits,
                                float max_nits);

// Half-float bit pattern -> tone-mapped 8-bit value table. Built once per
// (SDR white level, exposure) pair (65536 pow() entries, ~1 ms). Pixels
// whose max channel sits in the linear part of the curve map with 3 table
// lookups (the whole frame when nothing is above SDR white); pixels in the
// shoulder take the hue-preserving path (one curve ratio for the pixel,
// three multiplies, three encode-table lookups).
class ToneMapLut {
 public:
  // Builds (or rebuilds) for |sdr_white_nits| + |exposure|; no-op when
  // already built for the same values.
  void Build(float sdr_white_nits, ToneMapExposure exposure = {});
  bool built() const { return !lut_.empty(); }

  // Tightly-packed RGBA16F -> BGRA8888 (alpha forced opaque).
  void MapToBgra(const uint16_t* rgba_f16, size_t px_count,
                 uint8_t* out_bgra) const;
  // Tightly-packed RGBA16F -> RGBA8888 (alpha forced opaque; the loupe patch
  // byte order).
  void MapToRgba(const uint16_t* rgba_f16, size_t px_count,
                 uint8_t* out_rgba) const;

 private:
  // One pixel through the shoulder: |m_bits| is the pixel's max channel.
  void MapShoulder(const uint16_t* rgb_f16, uint16_t m_bits, uint8_t* r,
                   uint8_t* g, uint8_t* b) const;

  float built_for_ = -1.0f;
  ToneMapExposure built_exposure_;
  float scale_ = 1.0f;  // scRGB -> relative to SDR white
  // Highest half bit pattern still in the linear part of the curve; above it
  // the pixel goes through MapShoulder. 0xFFFF == no shoulder (clip only).
  uint16_t linear_limit_bits_ = 0xFFFF;
  std::vector<uint8_t> lut_;  // 65536: half bits -> 8-bit sRGB
};

}  // namespace hdr

#endif  // RUNNER_HDR_UTIL_H_
