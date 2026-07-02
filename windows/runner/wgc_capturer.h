#ifndef RUNNER_WGC_CAPTURER_H_
#define RUNNER_WGC_CAPTURER_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <vector>

// A single captured frame: tightly-packed BGRA8888 (premultiplied, sRGB),
// stride == width * 4. On an HDR monitor the capture runs in fp16 scRGB and
// |bgra| holds the tone-mapped SDR rendition (the wash-out fix); |f16| then
// optionally retains the raw RGBA16F pixels (stride width * 8) for an HDR
// output file. |f16| is empty on SDR monitors or when not requested.
struct CaptureFrame {
  std::vector<uint8_t> bgra;
  std::vector<uint8_t> f16;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t stride = 0;
  float sdr_white_nits = 240.0f;  // tone-map input (HDR captures only)
  float max_nits = 1000.0f;       // monitor peak (HDR10 metadata hint)
};

// One-shot screen capture via Windows.Graphics.Capture (border-free on Win11).
namespace wgc {

// Capture a whole monitor. nullopt on failure (caller may fall back).
// [keep_f16]: retain the raw fp16 pixels when the monitor is HDR.
std::optional<CaptureFrame> CaptureMonitor(HMONITOR monitor, bool show_cursor,
                                           bool keep_f16 = false);

// Capture a single window's own surface. nullopt on failure (caller falls back
// to a monitor capture cropped to the window rect).
std::optional<CaptureFrame> CaptureWindow(HWND window, bool show_cursor,
                                          bool keep_f16 = false);

}  // namespace wgc

#endif  // RUNNER_WGC_CAPTURER_H_
