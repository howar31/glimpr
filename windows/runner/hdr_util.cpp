#include "hdr_util.h"

#include <dxgi1_6.h>
#include <shlobj.h>

#include <cmath>
#include <cstdio>
#include <cstring>
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
        return info;
      }
      output->Release();
    }
    adapter->Release();
  }
  f->Release();
  return info;  // monitor not found (e.g. session 0) -> non-HDR defaults
}

bool ReadHdrScreenshotSetting() {
  PWSTR roaming = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                  &roaming))) {
    return false;
  }
  std::wstring path(roaming);
  CoTaskMemFree(roaming);
  path += L"\\com.example\\glimpr\\shared_preferences.json";
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return false;
  std::string json;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) json.append(buf, n);
  fclose(f);
  // Flat compact JSON from shared_preferences: a dumb substring probe is
  // enough (the key is ASCII and unique).
  const size_t key = json.find("\"hdr_screenshot\"");
  if (key == std::string::npos) return false;
  const size_t colon = json.find(':', key);
  if (colon == std::string::npos) return false;
  size_t v = colon + 1;
  while (v < json.size() && (json[v] == ' ' || json[v] == '\t')) ++v;
  return json.compare(v, 4, "true") == 0;
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

void ToneMapLut::Build(float sdr_white_nits) {
  if (!lut_.empty() && built_for_ == sdr_white_nits) return;
  built_for_ = sdr_white_nits;
  lut_.resize(65536);
  const float scale = 80.0f / (sdr_white_nits > 1.0f ? sdr_white_nits : 80.0f);
  for (uint32_t bits = 0; bits < 65536; ++bits) {
    float v = HalfToFloat(static_cast<uint16_t>(bits)) * scale;
    if (!(v > 0.0f)) v = 0.0f;  // negatives + NaN -> 0
    if (v > 1.0f) v = 1.0f;     // HDR highlights clip to white (faithful SDR)
    lut_[bits] =
        static_cast<uint8_t>(SrgbEncode(v) * 255.0f + 0.5f);
  }
}

void ToneMapLut::MapToBgra(const uint16_t* rgba_f16, size_t px_count,
                           uint8_t* out_bgra) const {
  const uint8_t* lut = lut_.data();
  for (size_t i = 0; i < px_count; ++i) {
    const uint16_t* p = rgba_f16 + i * 4;
    uint8_t* d = out_bgra + i * 4;
    d[0] = lut[p[2]];  // B
    d[1] = lut[p[1]];  // G
    d[2] = lut[p[0]];  // R
    d[3] = 255;
  }
}

void ToneMapLut::MapToRgba(const uint16_t* rgba_f16, size_t px_count,
                           uint8_t* out_rgba) const {
  const uint8_t* lut = lut_.data();
  for (size_t i = 0; i < px_count; ++i) {
    const uint16_t* p = rgba_f16 + i * 4;
    uint8_t* d = out_rgba + i * 4;
    d[0] = lut[p[0]];  // R
    d[1] = lut[p[1]];  // G
    d[2] = lut[p[2]];  // B
    d[3] = 255;
  }
}

}  // namespace hdr
