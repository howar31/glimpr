#include "hdr_compose.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "hdr_util.h"
#include "image_codec.h"

namespace hdrc {

namespace {

struct Rectd {
  double x0, y0, x1, y1;
  double w() const { return x1 - x0; }
  double h() const { return y1 - y0; }
};

Rectd Intersect(const Rectd& a, const Rectd& b) {
  return {(std::max)(a.x0, b.x0), (std::max)(a.y0, b.y0),
          (std::min)(a.x1, b.x1), (std::min)(a.y1, b.y1)};
}

// The pristine base, fetched in the working domain (extended sRGB gamma,
// relative to SDR white). Clamp-to-edge.
class BaseSampler {
 public:
  BaseSampler(const uint16_t* f16, uint32_t w, uint32_t h, float inv_white)
      : f16_(f16), w_(w), h_(h), inv_white_(inv_white) {}

  void Fetch(int x, int y, float out[3]) const {
    x = (std::min)((std::max)(x, 0), static_cast<int>(w_) - 1);
    y = (std::min)((std::max)(y, 0), static_cast<int>(h_) - 1);
    const uint16_t* p = f16_ + (static_cast<size_t>(y) * w_ + x) * 4;
    for (int c = 0; c < 3; ++c) {
      float lin = hdr::HalfToFloatScalar(p[c]) * inv_white_;
      if (!(lin > 0.0f)) lin = 0.0f;
      out[c] = hdr::ExtSrgbEncode(lin);
    }
  }

  // Bilinear fetch at a continuous position (pixel centres at +0.5).
  void FetchBilinear(double fx, double fy, float out[3]) const {
    const double px = fx - 0.5, py = fy - 0.5;
    const int x0 = static_cast<int>(std::floor(px));
    const int y0 = static_cast<int>(std::floor(py));
    const float tx = static_cast<float>(px - x0);
    const float ty = static_cast<float>(py - y0);
    float c00[3], c10[3], c01[3], c11[3];
    Fetch(x0, y0, c00);
    Fetch(x0 + 1, y0, c10);
    Fetch(x0, y0 + 1, c01);
    Fetch(x0 + 1, y0 + 1, c11);
    for (int c = 0; c < 3; ++c) {
      const float top = c00[c] + (c10[c] - c00[c]) * tx;
      const float bot = c01[c] + (c11[c] - c01[c]) * tx;
      out[c] = top + (bot - top) * ty;
    }
  }

  uint32_t w() const { return w_; }
  uint32_t h() const { return h_; }

 private:
  const uint16_t* f16_;
  uint32_t w_, h_;
  float inv_white_;
};

// A small float RGB image (the downsampled effect sources).
struct SmallImage {
  int w = 0, h = 0;
  std::vector<float> rgb;  // w*h*3
  float* px(int x, int y) { return rgb.data() + (static_cast<size_t>(y) * w + x) * 3; }
  const float* px(int x, int y) const {
    return rgb.data() + (static_cast<size_t>(y) * w + x) * 3;
  }
};

// Box-average downsample of the base over |src| (frame px) into a grid of
// |gw| x |gh| cells (mirrors the Dart medium-quality downsample closely
// enough for blurred/pixelated content).
SmallImage DownsampleBase(const BaseSampler& base, const Rectd& src, int gw,
                          int gh) {
  SmallImage out;
  out.w = gw;
  out.h = gh;
  out.rgb.assign(static_cast<size_t>(gw) * gh * 3, 0.0f);
  const double cw = src.w() / gw, ch = src.h() / gh;
  for (int gy = 0; gy < gh; ++gy) {
    for (int gx = 0; gx < gw; ++gx) {
      const int x0 = static_cast<int>(std::floor(src.x0 + gx * cw));
      const int y0 = static_cast<int>(std::floor(src.y0 + gy * ch));
      const int x1 = (std::max)(x0 + 1, static_cast<int>(std::ceil(src.x0 + (gx + 1) * cw)));
      const int y1 = (std::max)(y0 + 1, static_cast<int>(std::ceil(src.y0 + (gy + 1) * ch)));
      float acc[3] = {0, 0, 0};
      int n = 0;
      float texel[3];
      for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
          base.Fetch(x, y, texel);
          acc[0] += texel[0];
          acc[1] += texel[1];
          acc[2] += texel[2];
          ++n;
        }
      }
      float* dst = out.px(gx, gy);
      if (n > 0) {
        dst[0] = acc[0] / n;
        dst[1] = acc[1] / n;
        dst[2] = acc[2] / n;
      }
    }
  }
  return out;
}

// Separable gaussian blur (clamp edges) on a SmallImage.
void GaussianBlurSmall(SmallImage& img, double sigma) {
  if (sigma <= 0.05 || img.w <= 0 || img.h <= 0) return;
  const int radius = (std::max)(1, static_cast<int>(std::ceil(sigma * 3)));
  std::vector<float> kernel(radius + 1);
  double sum = 0;
  for (int i = 0; i <= radius; ++i) {
    kernel[i] = static_cast<float>(std::exp(-(i * i) / (2.0 * sigma * sigma)));
    sum += kernel[i] * (i == 0 ? 1 : 2);
  }
  for (auto& k : kernel) k = static_cast<float>(k / sum);

  SmallImage tmp = img;
  // Horizontal.
  for (int y = 0; y < img.h; ++y) {
    for (int x = 0; x < img.w; ++x) {
      float acc[3] = {0, 0, 0};
      for (int i = -radius; i <= radius; ++i) {
        const int sx = (std::min)((std::max)(x + i, 0), img.w - 1);
        const float* p = tmp.px(sx, y);
        const float k = kernel[std::abs(i)];
        acc[0] += p[0] * k;
        acc[1] += p[1] * k;
        acc[2] += p[2] * k;
      }
      float* d = img.px(x, y);
      d[0] = acc[0];
      d[1] = acc[1];
      d[2] = acc[2];
    }
  }
  tmp = img;
  // Vertical.
  for (int y = 0; y < img.h; ++y) {
    for (int x = 0; x < img.w; ++x) {
      float acc[3] = {0, 0, 0};
      for (int i = -radius; i <= radius; ++i) {
        const int sy = (std::min)((std::max)(y + i, 0), img.h - 1);
        const float* p = tmp.px(x, sy);
        const float k = kernel[std::abs(i)];
        acc[0] += p[0] * k;
        acc[1] += p[1] * k;
        acc[2] += p[2] * k;
      }
      float* d = img.px(x, y);
      d[0] = acc[0];
      d[1] = acc[1];
      d[2] = acc[2];
    }
  }
}

void SampleSmallBilinear(const SmallImage& img, double fx, double fy,
                         float out[3]) {
  const double px = fx - 0.5, py = fy - 0.5;
  int x0 = static_cast<int>(std::floor(px));
  int y0 = static_cast<int>(std::floor(py));
  const float tx = static_cast<float>(px - x0);
  const float ty = static_cast<float>(py - y0);
  const auto cl = [&](int v, int hi) { return (std::min)((std::max)(v, 0), hi); };
  const int xa = cl(x0, img.w - 1), xb = cl(x0 + 1, img.w - 1);
  const int ya = cl(y0, img.h - 1), yb = cl(y0 + 1, img.h - 1);
  const float* c00 = img.px(xa, ya);
  const float* c10 = img.px(xb, ya);
  const float* c01 = img.px(xa, yb);
  const float* c11 = img.px(xb, yb);
  for (int c = 0; c < 3; ++c) {
    const float top = c00[c] + (c10[c] - c00[c]) * tx;
    const float bot = c01[c] + (c11[c] - c01[c]) * tx;
    out[c] = top + (bot - top) * ty;
  }
}

// Mirror of lib/editor/raster.dart blurRegion: inflate by 3 sigma, blur,
// (down)sampled result stretched back over the region. Returns the small
// blurred image + the inflated source rect used for mapping.
struct BlurResult {
  SmallImage img;
  Rectd src;
  double factor = 1;
};

BlurResult BlurRegion(const BaseSampler& base, const Rectd& region,
                      double sigma) {
  BlurResult r;
  const Rectd frame{0, 0, static_cast<double>(base.w()),
                    static_cast<double>(base.h())};
  const double margin = std::ceil(sigma * 3);
  r.src = Intersect({region.x0 - margin, region.y0 - margin,
                     region.x1 + margin, region.y1 + margin},
                    frame);
  r.factor = (std::max)(1.0, std::floor(sigma / 2));
  const int gw = (std::max)(1, static_cast<int>(std::ceil(r.src.w() / r.factor)));
  const int gh = (std::max)(1, static_cast<int>(std::ceil(r.src.h() / r.factor)));
  r.img = DownsampleBase(base, r.src, gw, gh);
  GaussianBlurSmall(r.img, sigma / r.factor);
  return r;
}

// erf approximation (Abramowitz-Stegun 7.1.26) for the feathered hole edge.
float Erf(float x) {
  const float sign = x < 0 ? -1.0f : 1.0f;
  x = std::fabs(x);
  const float t = 1.0f / (1.0f + 0.3275911f * x);
  const float y =
      1.0f -
      (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t -
        0.284496736f) *
           t +
       0.254829592f) *
          t * std::exp(-x * x);
  return sign * y;
}

// Gaussian-feathered coverage of a filled rounded rect at point (px, py):
// ~ the MaskFilter.blur(normal, sigma) result the Dart layer uses.
float RRectCoverage(double px, double py, const Hole& hole, double sigma) {
  const double hw = hole.w / 2, hh = hole.h / 2;
  const double r = (std::min)({hole.radius, hw, hh});
  const double cx = hole.x + hw, cy = hole.y + hh;
  const double qx = std::fabs(px - cx) - (hw - r);
  const double qy = std::fabs(py - cy) - (hh - r);
  const double ox = (std::max)(qx, 0.0), oy = (std::max)(qy, 0.0);
  const double d =
      std::sqrt(ox * ox + oy * oy) + (std::min)((std::max)(qx, qy), 0.0) - r;
  if (sigma <= 0.01) return d < 0 ? 1.0f : 0.0f;
  // coverage = P(gaussian-blurred edge) = 0.5 * erfc(d / (sigma * sqrt(2)))
  return 0.5f * (1.0f - Erf(static_cast<float>(d / (sigma * 1.4142135))));
}

}  // namespace

std::vector<uint8_t> ComposeToJxr(
    const uint16_t* base_f16, uint32_t base_w, uint32_t base_h,
    float sdr_white_nits, int crop_x, int crop_y, int crop_w, int crop_h,
    const std::vector<Item>& items, const uint8_t* mask_bgra, int mask_w,
    int mask_h, int mask_row) {
  if (!base_f16 || base_w == 0 || base_h == 0 || crop_w <= 0 || crop_h <= 0) {
    return {};
  }
  const float white = sdr_white_nits > 1.0f ? sdr_white_nits / 80.0f : 1.0f;
  const BaseSampler base(base_f16, base_w, base_h, 1.0f / white);
  const Rectd crop{static_cast<double>(crop_x), static_cast<double>(crop_y),
                   static_cast<double>(crop_x + crop_w),
                   static_cast<double>(crop_y + crop_h)};

  // Working buffer: crop-space RGBA float in the extended-gamma domain.
  const size_t px_count = static_cast<size_t>(crop_w) * crop_h;
  std::vector<float> work(px_count * 4);
  for (int y = 0; y < crop_h; ++y) {
    for (int x = 0; x < crop_w; ++x) {
      float* d = work.data() + (static_cast<size_t>(y) * crop_w + x) * 4;
      base.Fetch(crop_x + x, crop_y + y, d);
      d[3] = 1.0f;
    }
  }

  for (const auto& item : items) {
    switch (item.kind) {
      case Item::kOverlay: {
        if (item.rgba.size() <
            static_cast<size_t>(item.ow) * item.oh * 4) {
          break;
        }
        const int w = (std::min)(static_cast<int>(item.ow), crop_w);
        const int h = (std::min)(static_cast<int>(item.oh), crop_h);
        for (int y = 0; y < h; ++y) {
          const uint8_t* srow =
              item.rgba.data() + static_cast<size_t>(y) * item.ow * 4;
          float* drow = work.data() + static_cast<size_t>(y) * crop_w * 4;
          for (int x = 0; x < w; ++x) {
            const uint8_t* s = srow + static_cast<size_t>(x) * 4;
            if (s[3] == 0) continue;
            const float a = s[3] / 255.0f;
            float* dpx = drow + static_cast<size_t>(x) * 4;
            for (int c = 0; c < 3; ++c) {
              const float o = s[c] / 255.0f;
              dpx[c] = o * a + dpx[c] * (1.0f - a);
            }
          }
        }
        break;
      }
      case Item::kBlur: {
        const Rectd region{item.x, item.y, item.x + item.w, item.y + item.h};
        const BlurResult blur = BlurRegion(base, region, item.sigma);
        const Rectd out = Intersect(region, crop);
        float rgb[3];
        for (int y = static_cast<int>(std::floor(out.y0));
             y < static_cast<int>(std::ceil(out.y1)); ++y) {
          for (int x = static_cast<int>(std::floor(out.x0));
               x < static_cast<int>(std::ceil(out.x1)); ++x) {
            const int wx = x - crop_x, wy = y - crop_y;
            if (wx < 0 || wy < 0 || wx >= crop_w || wy >= crop_h) continue;
            SampleSmallBilinear(
                blur.img, (x + 0.5 - blur.src.x0) / blur.factor,
                (y + 0.5 - blur.src.y0) / blur.factor, rgb);
            float* d = work.data() + (static_cast<size_t>(wy) * crop_w + wx) * 4;
            d[0] = rgb[0];
            d[1] = rgb[1];
            d[2] = rgb[2];
          }
        }
        break;
      }
      case Item::kPixelate: {
        const Rectd region{item.x, item.y, item.x + item.w, item.y + item.h};
        const double cell = item.cell < 1 ? 1.0 : item.cell;
        const int gw = (std::max)(
            1, static_cast<int>(std::ceil(region.w() / cell)));
        const int gh = (std::max)(
            1, static_cast<int>(std::ceil(region.h() / cell)));
        const SmallImage grid = DownsampleBase(base, region, gw, gh);
        const Rectd out = Intersect(region, crop);
        for (int y = static_cast<int>(std::floor(out.y0));
             y < static_cast<int>(std::ceil(out.y1)); ++y) {
          for (int x = static_cast<int>(std::floor(out.x0));
               x < static_cast<int>(std::ceil(out.x1)); ++x) {
            const int wx = x - crop_x, wy = y - crop_y;
            if (wx < 0 || wy < 0 || wx >= crop_w || wy >= crop_h) continue;
            // Nearest-neighbour cell (grid origin = region top-left; the
            // small image spans the region uniformly, matching the Dart
            // stretch-over-rect draw).
            int gx = static_cast<int>((x + 0.5 - region.x0) / region.w() * gw);
            int gy = static_cast<int>((y + 0.5 - region.y0) / region.h() * gh);
            gx = (std::min)((std::max)(gx, 0), gw - 1);
            gy = (std::min)((std::max)(gy, 0), gh - 1);
            const float* s = grid.px(gx, gy);
            float* d = work.data() + (static_cast<size_t>(wy) * crop_w + wx) * 4;
            d[0] = s[0];
            d[1] = s[1];
            d[2] = s[2];
          }
        }
        break;
      }
      case Item::kMagnify: {
        if (item.dw <= 0 || item.dh <= 0) break;
        const Rectd dest{item.dx, item.dy, item.dx + item.dw,
                         item.dy + item.dh};
        const Rectd out = Intersect(dest, crop);
        float rgb[3];
        for (int y = static_cast<int>(std::floor(out.y0));
             y < static_cast<int>(std::ceil(out.y1)); ++y) {
          for (int x = static_cast<int>(std::floor(out.x0));
               x < static_cast<int>(std::ceil(out.x1)); ++x) {
            const int wx = x - crop_x, wy = y - crop_y;
            if (wx < 0 || wy < 0 || wx >= crop_w || wy >= crop_h) continue;
            const double u = item.sx + (x + 0.5 - dest.x0) / dest.w() * item.sw;
            const double v = item.sy + (y + 0.5 - dest.y0) / dest.h() * item.sh;
            base.FetchBilinear(u, v, rgb);
            float* d = work.data() + (static_cast<size_t>(wy) * crop_w + wx) * 4;
            d[0] = rgb[0];
            d[1] = rgb[1];
            d[2] = rgb[2];
          }
        }
        break;
      }
      case Item::kSpotlight: {
        // The layer content (premultiplied): optional full-frame effect of the
        // base, dimmed toward black; alpha 1 with an effect, else = dim.
        const bool has_effect = item.sp_effect != 0;
        const float dim =
            static_cast<float>((std::min)((std::max)(item.sp_dim, 0.0), 1.0));
        if (!has_effect && dim <= 0.0f) break;
        const Rectd frame{0, 0, static_cast<double>(base_w),
                          static_cast<double>(base_h)};
        BlurResult blur;
        SmallImage grid;
        int gw = 0, gh = 0;
        if (item.sp_effect == 1) {
          blur = BlurRegion(base, frame, item.sp_strength);
        } else if (item.sp_effect == 2) {
          const double cell = item.sp_strength < 1 ? 1.0 : item.sp_strength;
          gw = (std::max)(1, static_cast<int>(std::ceil(frame.w() / cell)));
          gh = (std::max)(1, static_cast<int>(std::ceil(frame.h() / cell)));
          grid = DownsampleBase(base, frame, gw, gh);
        }
        const float layer_a0 = has_effect ? 1.0f : dim;
        float rgb[3];
        for (int wy = 0; wy < crop_h; ++wy) {
          for (int wx = 0; wx < crop_w; ++wx) {
            const double fx = crop_x + wx + 0.5, fy = crop_y + wy + 0.5;
            float lr = 0, lg = 0, lb = 0;
            if (item.sp_effect == 1) {
              SampleSmallBilinear(blur.img, (fx - blur.src.x0) / blur.factor,
                                  (fy - blur.src.y0) / blur.factor, rgb);
              lr = rgb[0] * (1.0f - dim);
              lg = rgb[1] * (1.0f - dim);
              lb = rgb[2] * (1.0f - dim);
            } else if (item.sp_effect == 2) {
              int gx = static_cast<int>(fx / frame.w() * gw);
              int gy = static_cast<int>(fy / frame.h() * gh);
              gx = (std::min)((std::max)(gx, 0), gw - 1);
              gy = (std::min)((std::max)(gy, 0), gh - 1);
              const float* s = grid.px(gx, gy);
              lr = s[0] * (1.0f - dim);
              lg = s[1] * (1.0f - dim);
              lb = s[2] * (1.0f - dim);
            }
            float la = layer_a0;
            // Every hole scales the (premultiplied) layer down: dstOut with a
            // feathered rounded-rect, sequentially like the Dart pass.
            for (const auto& hole : item.holes) {
              const float cov = RRectCoverage(fx, fy, hole, item.sp_feather);
              if (cov <= 0.0f) continue;
              const float keep = 1.0f - cov;
              la *= keep;
              lr *= keep;
              lg *= keep;
              lb *= keep;
            }
            if (la <= 0.0f && lr <= 0.0f && lg <= 0.0f && lb <= 0.0f) continue;
            float* d =
                work.data() + (static_cast<size_t>(wy) * crop_w + wx) * 4;
            d[0] = lr + d[0] * (1.0f - la);
            d[1] = lg + d[1] * (1.0f - la);
            d[2] = lb + d[2] * (1.0f - la);
          }
        }
        break;
      }
    }
  }

  // Window-snap silhouette: dstIn alpha, mask stretched over the crop.
  if (mask_bgra && mask_w > 0 && mask_h > 0) {
    for (int y = 0; y < crop_h; ++y) {
      for (int x = 0; x < crop_w; ++x) {
        const double u = (x + 0.5) / crop_w * mask_w - 0.5;
        const double v = (y + 0.5) / crop_h * mask_h - 0.5;
        const auto cl = [](int a, int hi) {
          return (std::min)((std::max)(a, 0), hi);
        };
        const int x0 = cl(static_cast<int>(std::floor(u)), mask_w - 1);
        const int x1 = cl(x0 + 1, mask_w - 1);
        const int y0 = cl(static_cast<int>(std::floor(v)), mask_h - 1);
        const int y1 = cl(y0 + 1, mask_h - 1);
        const float tx = static_cast<float>(u - std::floor(u));
        const float ty = static_cast<float>(v - std::floor(v));
        const auto A = [&](int mx, int my) -> float {
          return mask_bgra[static_cast<size_t>(my) * mask_row +
                           static_cast<size_t>(mx) * 4 + 3] /
                 255.0f;
        };
        const float top = A(x0, y0) + (A(x1, y0) - A(x0, y0)) * tx;
        const float bot = A(x0, y1) + (A(x1, y1) - A(x0, y1)) * tx;
        const float ma = top + (bot - top) * ty;
        work[(static_cast<size_t>(y) * crop_w + x) * 4 + 3] *= ma;
      }
    }
  }

  // Back to linear scRGB half floats + encode.
  std::vector<uint8_t> out_f16(px_count * 8);
  auto* dst = reinterpret_cast<uint16_t*>(out_f16.data());
  for (size_t i = 0; i < px_count; ++i) {
    const float* s = work.data() + i * 4;
    for (int c = 0; c < 3; ++c) {
      dst[i * 4 + c] =
          hdr::FloatToHalfScalar(hdr::ExtSrgbDecode(s[c]) * white);
    }
    dst[i * 4 + 3] = hdr::FloatToHalfScalar(s[3]);
  }
  return codec::EncodeJxr(out_f16.data(), static_cast<uint32_t>(crop_w),
                          static_cast<uint32_t>(crop_h),
                          static_cast<uint32_t>(crop_w) * 8,
                          /*force_opaque=*/mask_bgra == nullptr);
}

}  // namespace hdrc
