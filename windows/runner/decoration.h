#ifndef RUNNER_DECORATION_H_
#define RUNNER_DECORATION_H_

#include <cstdint>
#include <optional>

#include "wgc_capturer.h"  // CaptureFrame

namespace deco {

// CLSID_D2D1Shadow value with our own storage: d2d1effects.h declares the
// symbol extern but no import lib provides it, so referencing the header
// symbol fails to link. {C67EA361-1863-4E69-89DB-695D3E9A5B6B}. Shared by the
// decoration and pin shadow effects.
extern const GUID kCLSID_D2D1Shadow;

// Decoration appearance (lengths LOGICAL; scaled by the display scale in
// Decorate). Mirrors the macOS Decoration.Spec.
struct DecoSpec {
  double margin = 0;
  double cornerRadius = 0;
  double shadowBlur = 0;
  double shadowDx = 0;
  double shadowDy = 0;  // Flutter sense: +y points DOWN
  uint32_t shadowArgb = 0;
  std::optional<uint32_t> fillArgb;  // nullopt -> transparent margins (PNG)
  bool shapeFromAlpha = false;       // window: cast the shadow from content alpha
};

// Decorate BGRA8888 content into a larger BGRA frame: margin + rounded corners
// + drop shadow (Direct2D). Returns nullopt on failure.
std::optional<CaptureFrame> Decorate(const CaptureFrame& content,
                                     const DecoSpec& spec, double scale);

}  // namespace deco

#endif  // RUNNER_DECORATION_H_
