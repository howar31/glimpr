#include "hdr_util.h"

#include <dxgi1_6.h>
#include <shlobj.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

namespace hdr {

namespace {

// IEEE 754 half -> float (scalar; used only while building the LUT).
float HalfToFloat(uint16_t h) {
  const uint32_t sign = (h & 0x8000u) << 16;
  uint32_t exp = (h >> 10) & 0x1Fu;
  uint32_t mant = h & 0x3FFu;
  uint32_t bits;
  if (exp == 0) {
    if (mant == 0) {
      bits = sign;  // +/- 0
    } else {
      // Subnormal: normalize.
      exp = 127 - 15 + 1;
      while ((mant & 0x400u) == 0) {
        mant <<= 1;
        --exp;
      }
      mant &= 0x3FFu;
      bits = sign | (exp << 23) | (mant << 13);
    }
  } else if (exp == 31) {
    bits = sign | 0x7F800000u | (mant << 13);  // inf / NaN
  } else {
    bits = sign | ((exp - 15 + 127) << 23) | (mant << 13);
  }
  float f;
  std::memcpy(&f, &bits, sizeof(f));
  return f;
}

// Linear [0,1] -> sRGB-encoded [0,1].
float SrgbEncode(float c) {
  if (c <= 0.0031308f) return 12.92f * c;
  return 1.055f * std::pow(c, 1.0f / 2.4f) - 0.055f;
}

// The GDI device name (\\.\DISPLAY<n>) for |monitor|, for matching a
// DisplayConfig path.
bool MonitorGdiName(HMONITOR monitor, wchar_t out[32]) {
  MONITORINFOEXW mi{};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(monitor, &mi)) return false;
  wcsncpy_s(out, 32, mi.szDevice, _TRUNCATE);
  return true;
}

// SDR white level (nits) for |monitor| via the DisplayConfig SDR_WHITE_LEVEL
// (raw is thousandths of the 80-nit reference). False when unavailable.
bool QuerySdrWhiteNits(HMONITOR monitor, float* out_nits) {
  wchar_t gdi_name[32];
  if (!MonitorGdiName(monitor, gdi_name)) return false;
  UINT32 num_paths = 0, num_modes = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &num_paths,
                                  &num_modes) != ERROR_SUCCESS) {
    return false;
  }
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(num_paths);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(num_modes);
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &num_paths, paths.data(),
                         &num_modes, modes.data(), nullptr) != ERROR_SUCCESS) {
    return false;
  }
  for (UINT32 i = 0; i < num_paths; ++i) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME sn{};
    sn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    sn.header.size = sizeof(sn);
    sn.header.adapterId = paths[i].sourceInfo.adapterId;
    sn.header.id = paths[i].sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&sn.header) != ERROR_SUCCESS) continue;
    if (wcscmp(sn.viewGdiDeviceName, gdi_name) != 0) continue;
    DISPLAYCONFIG_SDR_WHITE_LEVEL wl{};
    wl.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
    wl.header.size = sizeof(wl);
    wl.header.adapterId = paths[i].targetInfo.adapterId;
    wl.header.id = paths[i].targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&wl.header) != ERROR_SUCCESS) return false;
    *out_nits = static_cast<float>(wl.SDRWhiteLevel) / 1000.0f * 80.0f;
    return *out_nits > 0.0f;
  }
  return false;
}

}  // namespace

MonitorHdrInfo QueryMonitorHdr(HMONITOR monitor) {
  // Short-TTL cache: every capture queries EVERY monitor (a fresh DXGI
  // factory + full adapter/output walk + DisplayConfig, a few ms on the
  // hotkey critical path), and live feeds / recordings re-query on start. A
  // 2s TTL keeps a capture burst free while an HDR toggle (or an HMONITOR
  // handle recycled by a topology change) is picked up within seconds.
  struct CacheEntry {
    MonitorHdrInfo info;
    ULONGLONG at_ms = 0;
  };
  static std::mutex cache_mutex;
  static std::map<HMONITOR, CacheEntry> cache;
  constexpr ULONGLONG kTtlMs = 2000;
  const ULONGLONG now = GetTickCount64();
  {
    std::lock_guard<std::mutex> lock(cache_mutex);
    auto it = cache.find(monitor);
    if (it != cache.end() && now - it->second.at_ms < kTtlMs) {
      return it->second.info;
    }
  }
  MonitorHdrInfo info;
  // Raw COM + explicit Release keeps this file free of winrt headers.
  IDXGIFactory1* f = nullptr;
  if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                reinterpret_cast<void**>(&f)))) {
    return info;
  }
  for (UINT a = 0;; ++a) {
    IDXGIAdapter1* adapter = nullptr;
    if (f->EnumAdapters1(a, &adapter) != S_OK) break;
    for (UINT o = 0;; ++o) {
      IDXGIOutput* output = nullptr;
      if (adapter->EnumOutputs(o, &output) != S_OK) break;
      DXGI_OUTPUT_DESC od{};
      if (SUCCEEDED(output->GetDesc(&od)) && od.Monitor == monitor) {
        IDXGIOutput6* out6 = nullptr;
        if (SUCCEEDED(output->QueryInterface(
                __uuidof(IDXGIOutput6), reinterpret_cast<void**>(&out6)))) {
          DXGI_OUTPUT_DESC1 d{};
          if (SUCCEEDED(out6->GetDesc1(&d))) {
            info.hdr =
                d.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
            info.color_space = static_cast<int>(d.ColorSpace);
            info.bits_per_color = static_cast<int>(d.BitsPerColor);
            if (d.MaxLuminance > 0) info.max_nits = d.MaxLuminance;
          }
          out6->Release();
        }
        output->Release();
        adapter->Release();
        f->Release();
        if (info.hdr) {
          float nits = 0;
          if (QuerySdrWhiteNits(monitor, &nits)) info.sdr_white_nits = nits;
        }
        {
          std::lock_guard<std::mutex> lock(cache_mutex);
          cache[monitor] = CacheEntry{info, now};
        }
        return info;
      }
      output->Release();
    }
    adapter->Release();
  }
  f->Release();
  // Monitor not found (e.g. session 0) -> non-HDR defaults; cached too so a
  // headless burst does not re-walk per display.
  {
    std::lock_guard<std::mutex> lock(cache_mutex);
    cache[monitor] = CacheEntry{info, now};
  }
  return info;
}

bool ReadPrefsBool(const char* key_name, bool dflt) {
  PWSTR roaming = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                  &roaming))) {
    return dflt;
  }
  std::wstring path(roaming);
  CoTaskMemFree(roaming);
  path += L"\\Howar31\\Glimpr\\shared_preferences.json";
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return dflt;
  std::string json;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) json.append(buf, n);
  fclose(f);
  // Flat compact JSON from shared_preferences: a dumb substring probe is
  // enough (the keys are ASCII and unique).
  const std::string quoted = std::string("\"") + key_name + "\"";
  const size_t key = json.find(quoted);
  if (key == std::string::npos) return dflt;
  const size_t colon = json.find(':', key);
  if (colon == std::string::npos) return dflt;
  size_t v = colon + 1;
  while (v < json.size() && (json[v] == ' ' || json[v] == '\t')) ++v;
  if (json.compare(v, 4, "true") == 0) return true;
  if (json.compare(v, 5, "false") == 0) return false;
  return dflt;
}

bool ReadHdrScreenshotSetting() {
  // Windows default OFF (the Dart getter's default is platform-split:
  // macOS on / Windows off).
  return ReadPrefsBool("hdr_screenshot", false);
}

float HalfToFloatScalar(uint16_t h) { return HalfToFloat(h); }

uint16_t FloatToHalfScalar(float f) {
  if (!(f == f)) return 0;  // NaN -> 0
  if (f <= 0.0f) return 0;  // negatives clamp (scRGB output stays >= 0 here)
  if (f >= 65504.0f) return 0x7BFF;  // max finite half
  uint32_t bits;
  std::memcpy(&bits, &f, sizeof(bits));
  const uint32_t exp = (bits >> 23) & 0xFF;
  const uint32_t mant = bits & 0x7FFFFF;
  if (exp < 113) {
    // Subnormal half (or underflow to 0).
    if (exp < 102) return 0;
    uint32_t m = mant | 0x800000;
    const uint32_t shift = 126 - exp;
    return static_cast<uint16_t>(m >> shift);
  }
  // Round-to-nearest on the dropped 13 bits.
  uint32_t half = ((exp - 112) << 10) | (mant >> 13);
  if (mant & 0x1000) ++half;
  return static_cast<uint16_t>(half);
}

float ExtSrgbEncode(float linear) {
  if (linear <= 0.0031308f) return 12.92f * linear;
  return 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
}

float ExtSrgbDecode(float encoded) {
  if (encoded <= 0.04045f) return encoded / 12.92f;
  return std::pow((encoded + 0.055f) / 1.055f, 2.4f);
}

namespace {

// Anything within this of SDR white is treated as SDR (fp16 rounding, app
// compositing noise); it clips to 255 either way.
constexpr float kAboveWhite = 1.0f + 1.0f / 255.0f;
// The bright percentile that becomes the exposure white point, and the
// top percentile that becomes the shoulder peak (stray pixels / the cursor
// glint never define it).
constexpr float kExposurePercentile = 0.95f;
constexpr float kPeakPercentile = 0.999f;
// How much of the frame must sit above SDR white before the exposure term
// engages (smoothstep between the two): below the low bound the frame is a
// desktop with some HDR content (keep SDR exact, shoulder only); above the
// high bound it is HDR content wall to wall (expose fully).
// Auto HDR keeps a game's mid-tones near SDR white and expands only the
// highlights, so a typical bright scene has ~40-45% of its pixels above SDR
// white and wants NO exposure change (the shoulder alone renders it); the
// exposure term is for content that is above SDR white wall to wall.
constexpr float kExposeFractionLo = 0.5f;
constexpr float kExposeFractionHi = 0.9f;
// Subsampling stride for the statistics scan (both axes).
constexpr uint32_t kMeasureStep = 4;

float SmoothStep(float lo, float hi, float x) {
  float t = (x - lo) / (hi - lo);
  if (t < 0.0f) t = 0.0f;
  if (t > 1.0f) t = 1.0f;
  return t * t * (3.0f - 2.0f * t);
}

// A channel's half bits normalised for max-channel comparison: negative and
// NaN texels count as 0, +inf as the largest finite half. For non-negative
// finite halves the bit order IS the value order.
inline uint16_t ChannelBits(uint16_t v) {
  if (v & 0x8000u) return 0;
  if (v > 0x7C00u) return 0;
  if (v == 0x7C00u) return 0x7BFFu;
  return v;
}

inline uint16_t MaxChannelBits(const uint16_t* px) {
  uint16_t m = ChannelBits(px[0]);
  const uint16_t g = ChannelBits(px[1]);
  const uint16_t b = ChannelBits(px[2]);
  if (g > m) m = g;
  if (b > m) m = b;
  return m;
}

// Half bits -> float, tabled (the shoulder path converts three channels per
// pixel; the scalar routine is only for table building).
const float* HalfTable() {
  static const std::vector<float> table = [] {
    std::vector<float> t(65536);
    for (uint32_t bits = 0; bits < 65536; ++bits) {
      t[bits] = HalfToFloat(static_cast<uint16_t>(bits));
    }
    return t;
  }();
  return table.data();
}

// Linear [0,1] -> 8-bit sRGB, tabled at 1/16383 steps (well under one 8-bit
// step everywhere on the curve).
constexpr uint32_t kEncodeSteps = 16384;
const uint8_t* EncodeTable() {
  static const std::vector<uint8_t> table = [] {
    std::vector<uint8_t> t(kEncodeSteps);
    for (uint32_t i = 0; i < kEncodeSteps; ++i) {
      const float v = static_cast<float>(i) / (kEncodeSteps - 1);
      t[i] = static_cast<uint8_t>(SrgbEncode(v) * 255.0f + 0.5f);
    }
    return t;
  }();
  return table.data();
}

inline uint8_t EncodeLinear(float v) {
  if (!(v > 0.0f)) return 0;
  if (v >= 1.0f) return 255;
  return EncodeTable()[static_cast<uint32_t>(v * (kEncodeSteps - 1) + 0.5f)];
}

}  // namespace

float ToneMapCurve(float rel, const ToneMapExposure& exposure) {
  if (!(rel > 0.0f)) return 0.0f;  // negatives + NaN -> 0
  const float white = exposure.white > 1.0f ? exposure.white : 1.0f;
  const float peak = exposure.peak;
  float t = rel / white;
  if (!(peak > kAboveWhite)) {
    // Nothing above white after exposure: the exact legacy clip.
    return t > 1.0f ? 1.0f : t;
  }
  const float knee = kToneMapKnee;
  if (t <= knee) return t;
  // Extended-Reinhard shoulder in knee-relative units: slope 1 at the knee
  // (C1), the frame peak lands exactly on 1.0, monotone throughout.
  const float width = 1.0f - knee;
  const float u = (t - knee) / width;
  const float cap = (peak - knee) / width;  // > 1 since peak > 1
  float y = u * (1.0f + u / (cap * cap)) / (1.0f + u);
  if (y > 1.0f) y = 1.0f;  // beyond the measured peak (stray pixels)
  return knee + width * y;
}

ToneMapExposure MeasureExposure(const uint16_t* rgba_f16, uint32_t width,
                                uint32_t height, float sdr_white_nits,
                                float max_nits) {
  ToneMapExposure ex;
  if (!rgba_f16 || width == 0 || height == 0) return ex;
  const float scale = 80.0f / (sdr_white_nits > 1.0f ? sdr_white_nits : 80.0f);
  // Histogram of max(R,G,B) by half bit pattern: for non-negative finite
  // halves the bit order IS the value order, so the percentiles fall out of
  // one cumulative walk. Sign bit set or NaN -> bin 0 (the curve maps them
  // to 0 too); +inf -> the largest finite bin.
  std::vector<uint32_t> hist(65536, 0);
  uint64_t total = 0;
  const uint32_t step = kMeasureStep;
  for (uint32_t y = 0; y < height; y += step) {
    const uint16_t* row = rgba_f16 + static_cast<size_t>(y) * width * 4;
    for (uint32_t x = 0; x < width; x += step) {
      ++hist[MaxChannelBits(row + static_cast<size_t>(x) * 4)];
      ++total;
    }
  }
  if (total == 0) return ex;
  // SDR white (relative 1.0) in half bits: the first bin strictly above it
  // marks "HDR content".
  const uint16_t white_bits = FloatToHalfScalar(kAboveWhite / scale);
  uint64_t above = 0;
  for (uint32_t b = white_bits + 1; b < 65536; ++b) above += hist[b];
  const float fraction = static_cast<float>(above) / static_cast<float>(total);

  auto percentile = [&](float q) -> float {
    const uint64_t target =
        static_cast<uint64_t>(q * static_cast<float>(total));
    uint64_t cum = 0;
    for (uint32_t b = 0; b < 65536; ++b) {
      cum += hist[b];
      if (cum > target) return HalfToFloat(static_cast<uint16_t>(b)) * scale;
    }
    return HalfToFloat(0x7BFFu) * scale;
  };
  const float rel_max =
      max_nits > sdr_white_nits ? max_nits / sdr_white_nits : 1.0f;

  float bright = percentile(kExposurePercentile);
  if (bright > rel_max) bright = rel_max;
  if (bright > 1.0f) {
    const float engage =
        SmoothStep(kExposeFractionLo, kExposeFractionHi, fraction);
    ex.white = 1.0f + (bright - 1.0f) * engage;
  }
  float top = percentile(kPeakPercentile);
  if (top > rel_max) top = rel_max;
  const float peak = top / ex.white;
  ex.peak = peak > 1.0f ? peak : 1.0f;
  return ex;
}

void ToneMapLut::Build(float sdr_white_nits, ToneMapExposure exposure) {
  if (!lut_.empty() && built_for_ == sdr_white_nits &&
      built_exposure_.white == exposure.white &&
      built_exposure_.peak == exposure.peak) {
    return;
  }
  built_for_ = sdr_white_nits;
  built_exposure_ = exposure;
  scale_ = 80.0f / (sdr_white_nits > 1.0f ? sdr_white_nits : 80.0f);
  lut_.resize(65536);
  for (uint32_t bits = 0; bits < 65536; ++bits) {
    const float rel = HalfToFloat(static_cast<uint16_t>(bits)) * scale_;
    const float v = ToneMapCurve(rel, exposure);
    lut_[bits] =
        static_cast<uint8_t>(SrgbEncode(v) * 255.0f + 0.5f);
  }
  // The curve is linear up to knee * white (relative); a pixel whose max
  // channel stays below that maps identically per channel, so only pixels
  // above it need the hue-preserving shoulder path.
  const float white = exposure.white > 1.0f ? exposure.white : 1.0f;
  if (exposure.peak > kAboveWhite) {
    const float limit_scrgb = kToneMapKnee * white / scale_;
    // Round DOWN so no shoulder pixel is misclassified as linear.
    uint16_t bits = FloatToHalfScalar(limit_scrgb);
    while (bits > 0 && HalfToFloat(bits) > limit_scrgb) --bits;
    linear_limit_bits_ = bits;
  } else {
    linear_limit_bits_ = 0xFFFF;  // clip only: every pixel is per-channel
  }
}

void ToneMapLut::MapShoulder(const uint16_t* rgb_f16, uint16_t m_bits,
                             uint8_t* r, uint8_t* g, uint8_t* b) const {
  const float* half = HalfTable();
  const float white =
      built_exposure_.white > 1.0f ? built_exposure_.white : 1.0f;
  const float inv_white = 1.0f / white;
  // The pixel's max channel through the curve; the other channels follow
  // with the same ratio so the colour keeps its hue and saturation.
  const float m_rel = half[m_bits] * scale_;
  const float m_out = ToneMapCurve(m_rel, built_exposure_);
  const float ratio = m_rel > 0.0f ? m_out / (m_rel * inv_white) : 0.0f;
  const float k = scale_ * inv_white * ratio;
  const float fr = half[ChannelBits(rgb_f16[0])] * k;
  const float fg = half[ChannelBits(rgb_f16[1])] * k;
  const float fb = half[ChannelBits(rgb_f16[2])] * k;
  *r = EncodeLinear(fr);
  *g = EncodeLinear(fg);
  *b = EncodeLinear(fb);
}

void ToneMapLut::MapToBgra(const uint16_t* rgba_f16, size_t px_count,
                           uint8_t* out_bgra) const {
  const uint8_t* lut = lut_.data();
  const uint16_t limit = linear_limit_bits_;
  for (size_t i = 0; i < px_count; ++i) {
    const uint16_t* p = rgba_f16 + i * 4;
    uint8_t* d = out_bgra + i * 4;
    const uint16_t m = limit == 0xFFFF ? 0 : MaxChannelBits(p);
    if (m <= limit) {
      d[0] = lut[p[2]];  // B
      d[1] = lut[p[1]];  // G
      d[2] = lut[p[0]];  // R
    } else {
      MapShoulder(p, m, d + 2, d + 1, d + 0);
    }
    d[3] = 255;
  }
}

void ToneMapLut::MapToRgba(const uint16_t* rgba_f16, size_t px_count,
                           uint8_t* out_rgba) const {
  const uint8_t* lut = lut_.data();
  const uint16_t limit = linear_limit_bits_;
  for (size_t i = 0; i < px_count; ++i) {
    const uint16_t* p = rgba_f16 + i * 4;
    uint8_t* d = out_rgba + i * 4;
    const uint16_t m = limit == 0xFFFF ? 0 : MaxChannelBits(p);
    if (m <= limit) {
      d[0] = lut[p[0]];  // R
      d[1] = lut[p[1]];  // G
      d[2] = lut[p[2]];  // B
    } else {
      MapShoulder(p, m, d + 0, d + 1, d + 2);
    }
    d[3] = 255;
  }
}

}  // namespace hdr
