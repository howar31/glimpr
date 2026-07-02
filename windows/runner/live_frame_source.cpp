#include "live_frame_source.h"

#include <d3d11.h>
#include <dxgi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <cstring>
#include <mutex>

#include "hdr_util.h"

namespace {

namespace cap = winrt::Windows::Graphics::Capture;
namespace dx = winrt::Windows::Graphics::DirectX;
namespace d3d = winrt::Windows::Graphics::DirectX::Direct3D11;

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

}  // namespace

struct LiveFrameSource::Impl {
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  winrt::com_ptr<ID3D11Texture2D> staging;  // latest frame, CPU-readable
  cap::GraphicsCaptureItem item{nullptr};
  cap::Direct3D11CaptureFramePool pool{nullptr};
  cap::GraphicsCaptureSession session{nullptr};
  winrt::event_token frame_token{};
  // Serializes the immediate context (CopyResource on the pool thread vs Map in
  // Sample on the UI thread -- the D3D11 immediate context is not thread-safe)
  // and the staging access.
  std::mutex mutex;
  uint32_t w = 0, h = 0;  // staging size (px)
  bool has_frame = false;
  // HDR monitor: the feed runs in fp16 scRGB and Sample() tone-maps each patch
  // (span^2 px, trivial) so the loupe reads faithful SDR colour.
  bool f16 = false;
  hdr::ToneMapLut tonemap;

  void OnFrameArrived();
};

void LiveFrameSource::Impl::OnFrameArrived() {
  std::lock_guard<std::mutex> lock(mutex);
  if (!pool) return;
  auto frame = pool.TryGetNextFrame();
  if (!frame) return;
  auto access =
      frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::
                             IDirect3DDxgiInterfaceAccess>();
  winrt::com_ptr<ID3D11Texture2D> texture;
  if (FAILED(access->GetInterface(__uuidof(ID3D11Texture2D),
                                  texture.put_void()))) {
    return;
  }
  D3D11_TEXTURE2D_DESC desc{};
  texture->GetDesc(&desc);
  if (!staging || w != desc.Width || h != desc.Height) {
    staging = nullptr;
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = desc.Width;
    sd.Height = desc.Height;
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.Format = f16 ? DXGI_FORMAT_R16G16B16A16_FLOAT
                    : DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(device->CreateTexture2D(&sd, nullptr, staging.put()))) return;
    w = desc.Width;
    h = desc.Height;
  }
  context->CopyResource(staging.get(), texture.get());
  has_frame = true;
}

LiveFrameSource::LiveFrameSource() : impl_(std::make_unique<Impl>()) {}
LiveFrameSource::~LiveFrameSource() { Stop(); }

bool LiveFrameSource::Start(HMONITOR monitor) {
  try {
    impl_->device = CreateD3DDevice();
    if (!impl_->device) return false;
    impl_->device->GetImmediateContext(impl_->context.put());
    auto rtDevice = WrapDevice(impl_->device);

    auto factory = winrt::get_activation_factory<cap::GraphicsCaptureItem>();
    auto interop = factory.as<IGraphicsCaptureItemInterop>();
    const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
    winrt::check_hresult(interop->CreateForMonitor(
        monitor, reinterpret_cast<GUID const&>(iid),
        winrt::put_abi(impl_->item)));

    auto size = impl_->item.Size();
    if (size.Width <= 0 || size.Height <= 0) return false;
    // HDR monitor -> fp16 scRGB feed + per-patch tone-map in Sample() (the
    // 8-bit OS conversion would hand the loupe washed-out colour).
    const hdr::MonitorHdrInfo hdr_info = hdr::QueryMonitorHdr(monitor);
    impl_->f16 = hdr_info.hdr;
    if (impl_->f16) impl_->tonemap.Build(hdr_info.sdr_white_nits);
    impl_->pool = cap::Direct3D11CaptureFramePool::CreateFreeThreaded(
        rtDevice,
        impl_->f16 ? dx::DirectXPixelFormat::R16G16B16A16Float
                   : dx::DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2, size);
    impl_->session = impl_->pool.CreateCaptureSession(impl_->item);
    try {
      impl_->session.IsBorderRequired(false);
    } catch (...) {
    }
    try {
      impl_->session.IsCursorCaptureEnabled(false);  // loupe shows screen, not cursor
    } catch (...) {
    }
    Impl* impl = impl_.get();
    impl_->frame_token = impl_->pool.FrameArrived(
        [impl](auto&&, auto&&) { impl->OnFrameArrived(); });
    impl_->session.StartCapture();
    return true;
  } catch (...) {
    Stop();
    return false;
  }
}

void LiveFrameSource::Stop() {
  if (impl_->frame_token && impl_->pool) {
    try {
      impl_->pool.FrameArrived(impl_->frame_token);
    } catch (...) {
    }
    impl_->frame_token = {};
  }
  if (impl_->session) {
    try {
      impl_->session.Close();
    } catch (...) {
    }
    impl_->session = nullptr;
  }
  if (impl_->pool) {
    try {
      impl_->pool.Close();
    } catch (...) {
    }
    impl_->pool = nullptr;
  }
  impl_->item = nullptr;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->staging = nullptr;
  impl_->context = nullptr;
  impl_->device = nullptr;
  impl_->has_frame = false;
  impl_->w = impl_->h = 0;
}

std::optional<std::vector<uint8_t>> LiveFrameSource::Sample(int center_x,
                                                           int center_y,
                                                           int span) {
  if (span <= 0) return std::nullopt;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (!impl_->has_frame || !impl_->staging || !impl_->context) {
    return std::nullopt;
  }
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(impl_->context->Map(impl_->staging.get(), 0, D3D11_MAP_READ, 0,
                                 &mapped))) {
    return std::nullopt;
  }
  const int W = static_cast<int>(impl_->w), H = static_cast<int>(impl_->h);
  const int half = span / 2;
  std::vector<uint8_t> out(static_cast<size_t>(span) * span * 4, 0);  // transparent
  const auto* base = static_cast<const uint8_t*>(mapped.pData);
  for (int row = 0; row < span; ++row) {
    const int y = center_y - half + row;
    if (y < 0 || y >= H) continue;
    for (int col = 0; col < span; ++col) {
      const int x = center_x - half + col;
      if (x < 0 || x >= W) continue;
      uint8_t* d = out.data() + (static_cast<size_t>(row) * span + col) * 4;
      if (impl_->f16) {
        // fp16 scRGB texel -> tone-mapped RGBA (one LUT lookup per channel).
        const uint16_t* p = reinterpret_cast<const uint16_t*>(
            base + static_cast<size_t>(y) * mapped.RowPitch +
            static_cast<size_t>(x) * 8);
        impl_->tonemap.MapToRgba(p, 1, d);
      } else {
        const uint8_t* p =
            base + static_cast<size_t>(y) * mapped.RowPitch +
            static_cast<size_t>(x) * 4;
        d[0] = p[2];  // R (source is BGRA)
        d[1] = p[1];  // G
        d[2] = p[0];  // B
        d[3] = 255;
      }
    }
  }
  impl_->context->Unmap(impl_->staging.get(), 0);
  return out;
}
