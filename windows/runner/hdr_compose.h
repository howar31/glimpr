#ifndef RUNNER_HDR_COMPOSE_H_
#define RUNNER_HDR_COMPOSE_H_

#include <cstdint>
#include <vector>

// The native HDR compositor for the annotated overlay export: replays the
// Dart editor's z-ordered output (overlay segments + base-sampling effect ops)
// on the freeze-retained fp16 scRGB base and encodes the result as JPEG XR.
//
// Space contract (mirrors lib/editor/hdr_plan.dart): the working buffer holds
// the base ENCODED with the extended sRGB curve RELATIVE TO SDR WHITE, so all
// blends/filters run in the exact domain the Dart (sRGB) composite uses --
// results match the SDR file everywhere the base is within SDR range, and the
// extended curve carries the highlights. Effect ops sample the PRISTINE base
// in FRAME space (a blur near the crop edge bleeds correctly); overlay
// segments are CROP-space straight-alpha RGBA bitmaps.
namespace hdrc {

struct Hole {
  double x = 0, y = 0, w = 0, h = 0;  // frame px
  double radius = 0;                  // native px
};

struct Item {
  enum Kind { kOverlay, kBlur, kPixelate, kMagnify, kSpotlight } kind =
      kOverlay;
  // kOverlay: crop-sized straight-alpha RGBA.
  std::vector<uint8_t> rgba;
  uint32_t ow = 0, oh = 0;
  // kBlur / kPixelate: region rect (frame px) + strength (native px).
  double x = 0, y = 0, w = 0, h = 0;
  double sigma = 0;  // blur
  double cell = 0;   // pixelate
  // kMagnify: source + destination rects (frame px).
  double sx = 0, sy = 0, sw = 0, sh = 0;
  double dx = 0, dy = 0, dw = 0, dh = 0;
  // kSpotlight: the ONE shared layer (full-canvas effect + dim + holes).
  int sp_effect = 0;  // 0 none, 1 blur, 2 pixelate
  double sp_strength = 0;
  double sp_dim = 0;      // 0..1
  double sp_feather = 0;  // gaussian sigma, native px
  std::vector<Hole> holes;
};

// Composite + encode. |base_f16| is the retained RGBA16F scRGB frame
// (stride = base_w * 8). Returns the encoded JXR bytes, empty on failure.
// |mask_bgra| (optional): the window-snap silhouette, stretched over the crop
// and applied as a dstIn alpha (rowBytes = mask_row).
std::vector<uint8_t> ComposeToJxr(
    const uint16_t* base_f16, uint32_t base_w, uint32_t base_h,
    float sdr_white_nits, int crop_x, int crop_y, int crop_w, int crop_h,
    const std::vector<Item>& items, const uint8_t* mask_bgra, int mask_w,
    int mask_h, int mask_row);

}  // namespace hdrc

#endif  // RUNNER_HDR_COMPOSE_H_
