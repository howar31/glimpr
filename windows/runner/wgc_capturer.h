#ifndef RUNNER_WGC_CAPTURER_H_
#define RUNNER_WGC_CAPTURER_H_

#include <windows.h>

#include <winrt/base.h>

#include <cstdint>
#include <optional>
#include <vector>

struct ID3D11Device;

namespace winrt::Windows::Graphics::DirectX::Direct3D11 {
struct IDirect3DDevice;
}

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

// A fresh hardware (WARP-fallback) BGRA-capable D3D11 device. The ONE shared
// creation helper for owners that keep their own device instance (recorder,
// pins, recording chrome, live loupe feeds) -- deduplicates the former
// per-file copies. The wgc captures themselves use an internal CACHED device
// (creating one measured tens of ms per capture); do not share instances
// across subsystems, the immediate context is not thread-safe.
winrt::com_ptr<ID3D11Device> CreateFreshD3DDevice();

// Wrap a D3D11 device as the WinRT IDirect3DDevice that
// Windows.Graphics.Capture consumes. Shared by the capture, the recorder, and
// the live loupe feeds (callers include the WinRT Direct3D11 headers).
winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice WrapDevice(
    winrt::com_ptr<ID3D11Device> const& device);

// Capture a whole monitor. nullopt on failure (caller may fall back).
// [keep_f16]: retain the raw fp16 pixels when the monitor is HDR.
// [force_opaque_alpha]: stamp alpha=255 into the returned BGRA during the
// readback row copy (cache-hot) -- the freeze overlay needs a fully opaque
// base because WGC monitor frames do not guarantee alpha==255 and the overlay
// window is permanent DWM glass (a see-through freeze would silently block
// the desktop). The captured monitor IS opaque, so the stamp is faithful.
std::optional<CaptureFrame> CaptureMonitor(HMONITOR monitor, bool show_cursor,
                                           bool keep_f16 = false,
                                           bool force_opaque_alpha = false);

// Capture a single window's own surface. nullopt on failure (caller falls back
// to a monitor capture cropped to the window rect).
std::optional<CaptureFrame> CaptureWindow(HWND window, bool show_cursor,
                                          bool keep_f16 = false);

}  // namespace wgc

#endif  // RUNNER_WGC_CAPTURER_H_
