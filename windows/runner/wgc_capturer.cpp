#include "wgc_capturer.h"

#include <d3d11.h>
#include <dxgi.h>

#include "hdr_util.h"
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <atomic>
#include <cstring>
#include <mutex>

namespace {

namespace cap = winrt::Windows::Graphics::Capture;
namespace dx = winrt::Windows::Graphics::DirectX;
namespace d3d = winrt::Windows::Graphics::DirectX::Direct3D11;

// Initialize the WinRT apartment once on this (the platform) thread. main.cpp
// already CoInitializeEx'd it as STA; this is idempotent and safe.
void EnsureWinrt() {
  static std::atomic<bool> done{false};
  bool expected = false;
  if (done.compare_exchange_strong(expected, true)) {
    try {
      winrt::init_apartment(winrt::apartment_type::single_threaded);
    } catch (...) {
      // Already initialized in a compatible mode.
    }
  }
}

winrt::com_ptr<ID3D11Device> CreateD3DDevice() {
  winrt::com_ptr<ID3D11Device> device;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0};
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2, D3D11_SDK_VERSION,
      device.put(), nullptr, nullptr);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                           D3D11_SDK_VERSION, device.put(), nullptr, nullptr);
  }
  return SUCCEEDED(hr) ? device : nullptr;
}

d3d::IDirect3DDevice WrapDevice(winrt::com_ptr<ID3D11Device> const& device) {
  auto dxgi = device.as<IDXGIDevice>();
  winrt::com_ptr<::IInspectable> inspectable;
  winrt::check_hresult(
      CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
  return inspectable.as<d3d::IDirect3DDevice>();
}

// Session-long cached capture device (creating one measured tens of ms per
// capture, on the hotkey->frozen critical path). D3D11 devices are
// free-threaded so the parallel per-monitor capture workers may share it, but
// the IMMEDIATE CONTEXT is not: the staging readback below serializes on
// g_readback_mutex. On failure a capture retries once with a recreated device
// (device-lost / GPU reset recovery).
std::mutex g_device_mutex;
winrt::com_ptr<ID3D11Device> g_shared_device;
d3d::IDirect3DDevice g_shared_rt_device{nullptr};
std::mutex g_readback_mutex;

bool SharedDevice(bool recreate, winrt::com_ptr<ID3D11Device>* out_d3d,
                  d3d::IDirect3DDevice* out_rt) {
  std::lock_guard<std::mutex> lock(g_device_mutex);
  if (recreate) {
    g_shared_device = nullptr;
    g_shared_rt_device = nullptr;
  }
  if (!g_shared_device) {
    g_shared_device = CreateD3DDevice();
    if (!g_shared_device) return false;
    try {
      g_shared_rt_device = WrapDevice(g_shared_device);
    } catch (...) {
      g_shared_device = nullptr;
      return false;
    }
  }
  *out_d3d = g_shared_device;
  *out_rt = g_shared_rt_device;
  return true;
}

winrt::com_ptr<IGraphicsCaptureItemInterop> GetInterop() {
  auto factory = winrt::get_activation_factory<cap::GraphicsCaptureItem>();
  return factory.as<IGraphicsCaptureItemInterop>();
}

std::optional<CaptureFrame> CaptureItem(cap::GraphicsCaptureItem const& item,
                                        bool show_cursor,
                                        const hdr::MonitorHdrInfo& hdr_info,
                                        bool keep_f16, bool force_opaque,
                                        bool fresh_device) {
  winrt::com_ptr<ID3D11Device> d3dDevice;
  d3d::IDirect3DDevice rtDevice{nullptr};
  if (!SharedDevice(fresh_device, &d3dDevice, &rtDevice)) return std::nullopt;

  // HDR monitor: capture in fp16 scRGB and tone-map to SDR ourselves (the OS
  // 8-bit conversion ignores the SDR white level -> washed-out output).
  const bool f16 = hdr_info.hdr;
  auto size = item.Size();
  auto pool = cap::Direct3D11CaptureFramePool::CreateFreeThreaded(
      rtDevice,
      f16 ? dx::DirectXPixelFormat::R16G16B16A16Float
          : dx::DirectXPixelFormat::B8G8R8A8UIntNormalized,
      1, size);
  auto session = pool.CreateCaptureSession(item);
  try {
    session.IsBorderRequired(false);
  } catch (...) {
  }
  try {
    session.IsCursorCaptureEnabled(show_cursor);
  } catch (...) {
  }

  winrt::handle ready{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
  auto token =
      pool.FrameArrived([&ready](auto&&, auto&&) { SetEvent(ready.get()); });

  session.StartCapture();
  WaitForSingleObject(ready.get(), 2000);
  pool.FrameArrived(token);

  std::optional<CaptureFrame> out;
  if (auto frame = pool.TryGetNextFrame()) {
    auto access = frame.Surface()
                      .as<::Windows::Graphics::DirectX::Direct3D11::
                              IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    winrt::check_hresult(
        access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));

    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);

    D3D11_TEXTURE2D_DESC staging_desc = desc;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;
    winrt::com_ptr<ID3D11Texture2D> staging;
    // The shared device's immediate context is not thread-safe: the parallel
    // per-monitor workers serialize their readbacks here (the WGC session
    // setup + frame wait above -- the expensive part -- still runs parallel).
    std::lock_guard<std::mutex> readback_lock(g_readback_mutex);
    if (SUCCEEDED(d3dDevice->CreateTexture2D(&staging_desc, nullptr,
                                             staging.put()))) {
      winrt::com_ptr<ID3D11DeviceContext> ctx;
      d3dDevice->GetImmediateContext(ctx.put());
      ctx->CopyResource(staging.get(), texture.get());
      D3D11_MAPPED_SUBRESOURCE mapped{};
      if (SUCCEEDED(ctx->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
        CaptureFrame cf;
        cf.width = desc.Width;
        cf.height = desc.Height;
        cf.stride = desc.Width * 4;
        cf.bgra.resize(static_cast<size_t>(cf.stride) * cf.height);
        const auto* src = static_cast<const uint8_t*>(mapped.pData);
        if (f16) {
          // Contiguous fp16 copy (stride width * 8), then tone-map to BGRA.
          cf.sdr_white_nits = hdr_info.sdr_white_nits;
          cf.max_nits = hdr_info.max_nits;
          const uint32_t f16_stride = desc.Width * 8;
          cf.f16.resize(static_cast<size_t>(f16_stride) * cf.height);
          for (uint32_t y = 0; y < cf.height; ++y) {
            std::memcpy(cf.f16.data() + static_cast<size_t>(y) * f16_stride,
                        src + static_cast<size_t>(y) * mapped.RowPitch,
                        f16_stride);
          }
          hdr::ToneMapLut lut;
          lut.Build(hdr_info.sdr_white_nits);
          lut.MapToBgra(reinterpret_cast<const uint16_t*>(cf.f16.data()),
                        static_cast<size_t>(cf.width) * cf.height,
                        cf.bgra.data());
          if (!keep_f16) {
            cf.f16.clear();
            cf.f16.shrink_to_fit();
          }
          if (force_opaque) {
            auto* px = reinterpret_cast<uint32_t*>(cf.bgra.data());
            const size_t n = static_cast<size_t>(cf.width) * cf.height;
            for (size_t i = 0; i < n; ++i) px[i] |= 0xFF000000u;
          }
        } else {
          for (uint32_t y = 0; y < cf.height; ++y) {
            uint8_t* dst = cf.bgra.data() + static_cast<size_t>(y) * cf.stride;
            std::memcpy(dst, src + static_cast<size_t>(y) * mapped.RowPitch,
                        cf.stride);
            if (force_opaque) {
              // Stamp alpha=255 while the row is hot in cache (a separate
              // full-frame pass measured meaningfully slower).
              auto* px = reinterpret_cast<uint32_t*>(dst);
              for (uint32_t x = 0; x < desc.Width; ++x) px[x] |= 0xFF000000u;
            }
          }
        }
        ctx->Unmap(staging.get(), 0);
        out = std::move(cf);
      }
    }
  }

  session.Close();
  pool.Close();
  return out;
}

}  // namespace

namespace wgc {

winrt::com_ptr<ID3D11Device> CreateFreshD3DDevice() { return CreateD3DDevice(); }

std::optional<CaptureFrame> CaptureMonitor(HMONITOR monitor, bool show_cursor,
                                           bool keep_f16,
                                           bool force_opaque_alpha) {
  EnsureWinrt();
  // Second attempt recreates the cached device (device-lost / GPU reset).
  for (int attempt = 0; attempt < 2; ++attempt) {
    try {
      auto interop = GetInterop();
      cap::GraphicsCaptureItem item{nullptr};
      const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
      winrt::check_hresult(interop->CreateForMonitor(
          monitor, reinterpret_cast<GUID const&>(iid), winrt::put_abi(item)));
      auto out = CaptureItem(item, show_cursor, hdr::QueryMonitorHdr(monitor),
                             keep_f16, force_opaque_alpha, attempt > 0);
      if (out) return out;
    } catch (...) {
    }
  }
  return std::nullopt;
}

std::optional<CaptureFrame> CaptureWindow(HWND window, bool show_cursor,
                                          bool keep_f16) {
  EnsureWinrt();
  // NO device-recreate retry here: a window capture's nullopt is a LEGIT fast
  // fallback signal (non-capturable windows -> rect-crop path) and each retry
  // would add the 2s frame-wait. A dead cached device recovers on the next
  // monitor capture (the fallback itself is one).
  try {
    auto interop = GetInterop();
    cap::GraphicsCaptureItem item{nullptr};
    const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
    winrt::check_hresult(interop->CreateForWindow(
        window, reinterpret_cast<GUID const&>(iid), winrt::put_abi(item)));
    HMONITOR mon = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
    return CaptureItem(item, show_cursor, hdr::QueryMonitorHdr(mon), keep_f16,
                       false, false);
  } catch (...) {
    return std::nullopt;
  }
}

}  // namespace wgc
