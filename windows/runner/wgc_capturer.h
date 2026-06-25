#ifndef RUNNER_WGC_CAPTURER_H_
#define RUNNER_WGC_CAPTURER_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <vector>

// A single captured frame: tightly-packed BGRA8888 (premultiplied, sRGB),
// stride == width * 4.
struct CaptureFrame {
  std::vector<uint8_t> bgra;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t stride = 0;
};

// One-shot screen capture via Windows.Graphics.Capture (border-free on Win11).
namespace wgc {

// Capture a whole monitor. nullopt on failure (caller may fall back).
std::optional<CaptureFrame> CaptureMonitor(HMONITOR monitor, bool show_cursor);

// Capture a single window's own surface. nullopt on failure (caller falls back
// to a monitor capture cropped to the window rect).
std::optional<CaptureFrame> CaptureWindow(HWND window, bool show_cursor);

}  // namespace wgc

#endif  // RUNNER_WGC_CAPTURER_H_
