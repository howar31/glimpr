#include "wgc_capturer.h"

#include <d3d11.h>
#include <dxgi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <atomic>
#include <cstring>

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

winrt::com_ptr<IGraphicsCaptureItemInterop> GetInterop() {
  auto factory = winrt::get_activation_factory<cap::GraphicsCaptureItem>();
  return factory.as<IGraphicsCaptureItemInterop>();
}

std::optional<CaptureFrame> CaptureItem(cap::GraphicsCaptureItem const& item,
                                        bool show_cursor) {
  auto d3dDevice = CreateD3DDevice();
  if (!d3dDevice) return std::nullopt;
  auto rtDevice = WrapDevice(d3dDevice);

  auto size = item.Size();
  auto pool = cap::Direct3D11CaptureFramePool::CreateFreeThreaded(
      rtDevice, dx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 1, size);
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
        for (uint32_t y = 0; y < cf.height; ++y) {
          std::memcpy(cf.bgra.data() + static_cast<size_t>(y) * cf.stride,
                      src + static_cast<size_t>(y) * mapped.RowPitch,
                      cf.stride);
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

std::optional<CaptureFrame> CaptureMonitor(HMONITOR monitor, bool show_cursor) {
  EnsureWinrt();
  try {
    auto interop = GetInterop();
    cap::GraphicsCaptureItem item{nullptr};
    const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
    winrt::check_hresult(interop->CreateForMonitor(
        monitor, reinterpret_cast<GUID const&>(iid), winrt::put_abi(item)));
    return CaptureItem(item, show_cursor);
  } catch (...) {
    return std::nullopt;
  }
}

std::optional<CaptureFrame> CaptureWindow(HWND window, bool show_cursor) {
  EnsureWinrt();
  try {
    auto interop = GetInterop();
    cap::GraphicsCaptureItem item{nullptr};
    const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
    winrt::check_hresult(interop->CreateForWindow(
        window, reinterpret_cast<GUID const&>(iid), winrt::put_abi(item)));
    return CaptureItem(item, show_cursor);
  } catch (...) {
    return std::nullopt;
  }
}

}  // namespace wgc
