// The pure part of the excluded-applications mask: list parsing, the
// rectangle arithmetic that decides which pixels to cover, and the black and
// blur fills.
// No Win32 calls (only the RECT/LONG types), so windows/test covers it;
// excluded_apps.cpp feeds it live window data.
#ifndef RUNNER_CAPTURE_MASK_H_
#define RUNNER_CAPTURE_MASK_H_

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <cwctype>
#include <string>
#include <vector>

namespace capmask {

// The identifier form of an exe path: forward slashes, lower case. Stored and
// compared in this form only, so the value needs no JSON escaping.
inline std::wstring NormalizePath(std::wstring path) {
  for (wchar_t& ch : path) {
    ch = (ch == L'\\') ? L'/' : static_cast<wchar_t>(std::towlower(ch));
  }
  return path;
}

// One stored entry: an application and how its windows are covered.
struct Entry {
  std::wstring path;  // normalized
  bool blur = false;  // false = solid black
};

// The stored list: entries joined by '|', each an exe path with an optional
// "?mode" suffix ("blur"; anything else, including the scopes another platform
// writes, means the default). Blank entries and duplicate paths are dropped.
inline std::vector<Entry> ParseList(const std::wstring& raw) {
  std::vector<Entry> out;
  size_t start = 0;
  while (start <= raw.size()) {
    size_t end = raw.find(L'|', start);
    if (end == std::wstring::npos) end = raw.size();
    size_t a = start;
    size_t b = end;
    const size_t mark = raw.find(L'?', start);
    std::wstring mode;
    if (mark != std::wstring::npos && mark < end) {
      mode = raw.substr(mark + 1, end - mark - 1);
      b = mark;
    }
    while (a < b && raw[a] == L' ') ++a;
    while (b > a && raw[b - 1] == L' ') --b;
    if (b > a) {
      Entry entry;
      entry.path = NormalizePath(raw.substr(a, b - a));
      entry.blur = mode == L"blur";
      bool seen = false;
      for (const Entry& have : out) {
        if (have.path == entry.path) seen = true;
      }
      if (!seen) out.push_back(std::move(entry));
    }
    start = end + 1;
  }
  return out;
}

// The entry for [exe_path], or null.
inline const Entry* Find(const std::vector<Entry>& list,
                         const std::wstring& exe_path) {
  if (list.empty() || exe_path.empty()) return nullptr;
  const std::wstring id = NormalizePath(exe_path);
  for (const Entry& have : list) {
    if (have.path == id) return &have;
  }
  return nullptr;
}

inline bool IsListed(const std::vector<Entry>& list,
                     const std::wstring& exe_path) {
  return Find(list, exe_path) != nullptr;
}

// One on-screen window, already filtered to visible / not minimized / not
// cloaked. [opaque] is false for a window whose pixels may show what is under
// it; such a window never hides a listed one.
struct Window {
  RECT rect{};
  bool listed = false;
  bool blur = false;  // listed windows only
  bool opaque = true;
};

// One area to cover, and how.
struct MaskRect {
  RECT rect{};
  bool blur = false;
};

inline bool Intersect(const RECT& a, const RECT& b, RECT* out) {
  RECT r{};
  r.left = a.left > b.left ? a.left : b.left;
  r.top = a.top > b.top ? a.top : b.top;
  r.right = a.right < b.right ? a.right : b.right;
  r.bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
  if (r.right <= r.left || r.bottom <= r.top) return false;
  *out = r;
  return true;
}

// Appends [a] minus [b] to [out] as up to four rectangles.
inline void Subtract(const RECT& a, const RECT& b, std::vector<RECT>* out) {
  RECT hit{};
  if (!Intersect(a, b, &hit)) {
    out->push_back(a);
    return;
  }
  if (hit.top > a.top) out->push_back(RECT{a.left, a.top, a.right, hit.top});
  if (hit.bottom < a.bottom) {
    out->push_back(RECT{a.left, hit.bottom, a.right, a.bottom});
  }
  if (hit.left > a.left) {
    out->push_back(RECT{a.left, hit.top, hit.left, hit.bottom});
  }
  if (hit.right < a.right) {
    out->push_back(RECT{hit.right, hit.top, a.right, hit.bottom});
  }
}

// The areas to cover inside [bounds], in the windows' own coordinate
// space: each listed window's rect minus every opaque, unlisted window in
// front of it. [front_to_back] is z-order, topmost first.
inline std::vector<MaskRect> MaskRects(
    const std::vector<Window>& front_to_back, const RECT& bounds) {
  std::vector<MaskRect> out;
  for (size_t i = 0; i < front_to_back.size(); ++i) {
    const Window& target = front_to_back[i];
    if (!target.listed) continue;
    RECT clipped{};
    if (!Intersect(target.rect, bounds, &clipped)) continue;
    std::vector<RECT> pieces{clipped};
    for (size_t j = 0; j < i && !pieces.empty(); ++j) {
      const Window& cover = front_to_back[j];
      if (cover.listed || !cover.opaque) continue;
      std::vector<RECT> next;
      for (const RECT& piece : pieces) Subtract(piece, cover.rect, &next);
      pieces.swap(next);
    }
    for (const RECT& piece : pieces) out.push_back(MaskRect{piece, target.blur});
  }
  return out;
}

// Clamps a frame-local rect to a width x height frame. False when empty.
inline bool ClampToFrame(const RECT& r, uint32_t width, uint32_t height,
                         RECT* out) {
  const RECT frame{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
  return Intersect(r, frame, out);
}

// Opaque black into BGRA8888 pixels ([stride] bytes per row).
inline void FillBgra(uint8_t* pixels, uint32_t width, uint32_t height,
                     uint32_t stride, const RECT& local) {
  RECT r{};
  if (!ClampToFrame(local, width, height, &r)) return;
  for (LONG y = r.top; y < r.bottom; ++y) {
    uint8_t* p = pixels + static_cast<size_t>(y) * stride +
                 static_cast<size_t>(r.left) * 4;
    for (LONG x = r.left; x < r.right; ++x) {
      p[0] = 0;
      p[1] = 0;
      p[2] = 0;
      p[3] = 255;
      p += 4;
    }
  }
}

// Opaque black into tightly packed RGBA16F pixels (width * 8 bytes per row):
// colour 0.0, alpha 1.0 (half-float 0x3C00, little-endian).
inline void FillF16(uint8_t* pixels, uint32_t width, uint32_t height,
                    const RECT& local) {
  RECT r{};
  if (!ClampToFrame(local, width, height, &r)) return;
  const size_t stride = static_cast<size_t>(width) * 8;
  for (LONG y = r.top; y < r.bottom; ++y) {
    uint8_t* p =
        pixels + static_cast<size_t>(y) * stride + static_cast<size_t>(r.left) * 8;
    for (LONG x = r.left; x < r.right; ++x) {
      p[0] = 0;
      p[1] = 0;
      p[2] = 0;
      p[3] = 0;
      p[4] = 0;
      p[5] = 0;
      p[6] = 0x00;
      p[7] = 0x3C;
      p += 8;
    }
  }
}

// --- blur -------------------------------------------------------------------

// Side of the averaging block, in pixels. The covered area is reduced to one
// colour per block and those colours are interpolated back, so nothing finer
// than a block survives.
constexpr int kBlurBlock = 24;

// Blurs the frame-local [r] (already clamped) through [load] / [store], which
// read and write one pixel's three colour channels as floats.
template <typename Load, typename Store>
inline void BlurRegion(const RECT& r, Load load, Store store) {
  const int rw = static_cast<int>(r.right - r.left);
  const int rh = static_cast<int>(r.bottom - r.top);
  if (rw <= 0 || rh <= 0) return;
  const int gw = (rw + kBlurBlock - 1) / kBlurBlock;
  const int gh = (rh + kBlurBlock - 1) / kBlurBlock;
  std::vector<float> grid(static_cast<size_t>(gw) * gh * 3, 0.0f);
  for (int gy = 0; gy < gh; ++gy) {
    const int y0 = gy * kBlurBlock;
    const int y1 = (y0 + kBlurBlock < rh) ? y0 + kBlurBlock : rh;
    for (int gx = 0; gx < gw; ++gx) {
      const int x0 = gx * kBlurBlock;
      const int x1 = (x0 + kBlurBlock < rw) ? x0 + kBlurBlock : rw;
      float sum[3] = {0.0f, 0.0f, 0.0f};
      for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
          float c[3];
          load(r.left + x, r.top + y, c);
          sum[0] += c[0];
          sum[1] += c[1];
          sum[2] += c[2];
        }
      }
      const float n = static_cast<float>((x1 - x0) * (y1 - y0));
      float* cell = &grid[(static_cast<size_t>(gy) * gw + gx) * 3];
      cell[0] = sum[0] / n;
      cell[1] = sum[1] / n;
      cell[2] = sum[2] / n;
    }
  }
  for (int y = 0; y < rh; ++y) {
    float fy = (static_cast<float>(y) + 0.5f) / kBlurBlock - 0.5f;
    if (fy < 0.0f) fy = 0.0f;
    if (fy > static_cast<float>(gh - 1)) fy = static_cast<float>(gh - 1);
    const int ya = static_cast<int>(fy);
    const int yb = (ya + 1 < gh) ? ya + 1 : ya;
    const float ty = fy - static_cast<float>(ya);
    for (int x = 0; x < rw; ++x) {
      float fx = (static_cast<float>(x) + 0.5f) / kBlurBlock - 0.5f;
      if (fx < 0.0f) fx = 0.0f;
      if (fx > static_cast<float>(gw - 1)) fx = static_cast<float>(gw - 1);
      const int xa = static_cast<int>(fx);
      const int xb = (xa + 1 < gw) ? xa + 1 : xa;
      const float tx = fx - static_cast<float>(xa);
      const float* p00 = &grid[(static_cast<size_t>(ya) * gw + xa) * 3];
      const float* p01 = &grid[(static_cast<size_t>(ya) * gw + xb) * 3];
      const float* p10 = &grid[(static_cast<size_t>(yb) * gw + xa) * 3];
      const float* p11 = &grid[(static_cast<size_t>(yb) * gw + xb) * 3];
      float c[3];
      for (int k = 0; k < 3; ++k) {
        const float top = p00[k] + (p01[k] - p00[k]) * tx;
        const float bottom = p10[k] + (p11[k] - p10[k]) * tx;
        c[k] = top + (bottom - top) * ty;
      }
      store(r.left + x, r.top + y, c);
    }
  }
}

// Blurs BGRA8888 pixels ([stride] bytes per row); alpha becomes opaque.
inline void BlurBgra(uint8_t* pixels, uint32_t width, uint32_t height,
                     uint32_t stride, const RECT& local) {
  RECT r{};
  if (!ClampToFrame(local, width, height, &r)) return;
  BlurRegion(
      r,
      [pixels, stride](LONG x, LONG y, float* c) {
        const uint8_t* p = pixels + static_cast<size_t>(y) * stride +
                           static_cast<size_t>(x) * 4;
        c[0] = static_cast<float>(p[0]);
        c[1] = static_cast<float>(p[1]);
        c[2] = static_cast<float>(p[2]);
      },
      [pixels, stride](LONG x, LONG y, const float* c) {
        uint8_t* p = pixels + static_cast<size_t>(y) * stride +
                     static_cast<size_t>(x) * 4;
        p[0] = static_cast<uint8_t>(c[0] + 0.5f);
        p[1] = static_cast<uint8_t>(c[1] + 0.5f);
        p[2] = static_cast<uint8_t>(c[2] + 0.5f);
        p[3] = 255;
      });
}

// IEEE half <-> float for the values a capture holds (finite, non-negative
// after clamping); NaN and negatives encode as 0.
inline float HalfToFloat(uint16_t h) {
  const uint32_t sign = (static_cast<uint32_t>(h) & 0x8000u) << 16;
  uint32_t exp = (static_cast<uint32_t>(h) >> 10) & 0x1Fu;
  uint32_t mant = static_cast<uint32_t>(h) & 0x3FFu;
  uint32_t bits = 0;
  if (exp == 0) {
    if (mant != 0) {
      exp = 1;
      while ((mant & 0x400u) == 0) {
        mant <<= 1;
        --exp;
      }
      mant &= 0x3FFu;
      bits = sign | ((exp + 112u) << 23) | (mant << 13);
    } else {
      bits = sign;
    }
  } else if (exp == 31) {
    bits = sign | 0x7F800000u | (mant << 13);
  } else {
    bits = sign | ((exp + 112u) << 23) | (mant << 13);
  }
  float f = 0.0f;
  std::memcpy(&f, &bits, sizeof(f));
  return f;
}

inline uint16_t FloatToHalf(float f) {
  if (!(f > 0.0f)) return 0;
  if (f >= 65504.0f) return 0x7BFF;
  uint32_t bits = 0;
  std::memcpy(&bits, &f, sizeof(bits));
  const uint32_t exp = (bits >> 23) & 0xFFu;
  const uint32_t mant = bits & 0x7FFFFFu;
  if (exp < 113u) {
    if (exp < 103u) return 0;
    const uint32_t m = mant | 0x800000u;
    return static_cast<uint16_t>(m >> (126u - exp));
  }
  return static_cast<uint16_t>(((exp - 112u) << 10) | (mant >> 13));
}

// Blurs tightly packed RGBA16F pixels; alpha becomes 1.0.
inline void BlurF16(uint8_t* pixels, uint32_t width, uint32_t height,
                    const RECT& local) {
  RECT r{};
  if (!ClampToFrame(local, width, height, &r)) return;
  const size_t stride = static_cast<size_t>(width) * 8;
  BlurRegion(
      r,
      [pixels, stride](LONG x, LONG y, float* c) {
        const uint8_t* p =
            pixels + static_cast<size_t>(y) * stride + static_cast<size_t>(x) * 8;
        for (int k = 0; k < 3; ++k) {
          uint16_t h = 0;
          std::memcpy(&h, p + k * 2, sizeof(h));
          const float v = HalfToFloat(h);
          c[k] = (v == v && v > 0.0f) ? (v < 65504.0f ? v : 65504.0f) : 0.0f;
        }
      },
      [pixels, stride](LONG x, LONG y, const float* c) {
        uint8_t* p =
            pixels + static_cast<size_t>(y) * stride + static_cast<size_t>(x) * 8;
        for (int k = 0; k < 3; ++k) {
          const uint16_t h = FloatToHalf(c[k]);
          std::memcpy(p + k * 2, &h, sizeof(h));
        }
        p[6] = 0x00;
        p[7] = 0x3C;
      });
}

}  // namespace capmask

#endif  // RUNNER_CAPTURE_MASK_H_
