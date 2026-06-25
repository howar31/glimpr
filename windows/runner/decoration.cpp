#include "decoration.h"

#include <d2d1_1.h>
#include <d2d1effects.h>
#include <d3d11.h>
#include <dxgi.h>
#include <winrt/base.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

// CLSID_D2D1Shadow value, defined locally: the header declares it extern but no
// import lib provides the storage, so referencing the header symbol fails to
// link. {C67EA361-1863-4E69-89DB-695D3E9A5B6B}.
const GUID kCLSID_D2D1Shadow = {
    0xC67EA361,
    0x1863,
    0x4E69,
    {0x89, 0xDB, 0x69, 0x5D, 0x3E, 0x9A, 0x5B, 0x6B}};

D2D1_COLOR_F ColorFromArgb(uint32_t argb) {
  return D2D1::ColorF(((argb >> 16) & 0xFF) / 255.0f,
                      ((argb >> 8) & 0xFF) / 255.0f, (argb & 0xFF) / 255.0f,
                      ((argb >> 24) & 0xFF) / 255.0f);
}

winrt::com_ptr<ID3D11Device> CreateD3D() {
  winrt::com_ptr<ID3D11Device> d;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, d.put(), nullptr, nullptr))) {
    D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                      D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                      D3D11_SDK_VERSION, d.put(), nullptr, nullptr);
  }
  return d;
}

}  // namespace

namespace deco {

std::optional<CaptureFrame> Decorate(const CaptureFrame& content,
                                     const DecoSpec& spec, double scale) {
  if (content.bgra.empty() || content.width == 0 || content.height == 0) {
    return std::nullopt;
  }
  try {
    const float s = static_cast<float>(scale);
    const float blur = static_cast<float>(spec.shadowBlur) * s;
    const float dx = static_cast<float>(spec.shadowDx) * s;
    const float dy = static_cast<float>(spec.shadowDy) * s;
    const float radius = static_cast<float>(spec.cornerRadius) * s;
    const float m = (std::max)(static_cast<float>(spec.margin) * s,
                               blur + (std::max)(std::abs(dx), std::abs(dy)));
    const float cw = static_cast<float>(content.width);
    const float ch = static_cast<float>(content.height);
    const uint32_t out_w = static_cast<uint32_t>(std::lround(cw + 2 * m));
    const uint32_t out_h = static_cast<uint32_t>(std::lround(ch + 2 * m));

    auto d3d = CreateD3D();
    if (!d3d) return std::nullopt;
    auto dxgi = d3d.as<IDXGIDevice>();

    D2D1_FACTORY_OPTIONS fo{};
    winrt::com_ptr<ID2D1Factory1> factory;
    winrt::check_hresult(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                           __uuidof(ID2D1Factory1), &fo,
                                           factory.put_void()));
    winrt::com_ptr<ID2D1Device> device;
    winrt::check_hresult(factory->CreateDevice(dxgi.get(), device.put()));
    winrt::com_ptr<ID2D1DeviceContext> dc;
    winrt::check_hresult(device->CreateDeviceContext(
        D2D1_DEVICE_CONTEXT_OPTIONS_NONE, dc.put()));

    const auto pf = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                      D2D1_ALPHA_MODE_PREMULTIPLIED);
    const auto target_props =
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, pf);

    winrt::com_ptr<ID2D1Bitmap1> content_bmp;
    winrt::check_hresult(dc->CreateBitmap(
        D2D1::SizeU(content.width, content.height), content.bgra.data(),
        content.stride, D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_NONE, pf),
        content_bmp.put()));

    const D2D1_ROUNDED_RECT rr =
        D2D1::RoundedRect(D2D1::RectF(m, m, m + cw, m + ch), radius, radius);

    // Non shapeFromAlpha: render an opaque rounded-rect silhouette to cast the
    // shadow from the rounded shape.
    winrt::com_ptr<ID2D1Bitmap1> silhouette;
    if (!spec.shapeFromAlpha) {
      winrt::check_hresult(dc->CreateBitmap(D2D1::SizeU(out_w, out_h), nullptr,
                                            0, target_props, silhouette.put()));
      dc->SetTarget(silhouette.get());
      dc->BeginDraw();
      dc->Clear(D2D1::ColorF(0, 0, 0, 0));
      winrt::com_ptr<ID2D1SolidColorBrush> opaque;
      dc->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), opaque.put());
      dc->FillRoundedRectangle(rr, opaque.get());
      winrt::check_hresult(dc->EndDraw());
    }

    winrt::com_ptr<ID2D1Bitmap1> target;
    winrt::check_hresult(dc->CreateBitmap(D2D1::SizeU(out_w, out_h), nullptr, 0,
                                          target_props, target.put()));
    dc->SetTarget(target.get());
    dc->BeginDraw();
    dc->Clear(spec.fillArgb ? ColorFromArgb(*spec.fillArgb)
                            : D2D1::ColorF(0, 0, 0, 0));

    winrt::com_ptr<ID2D1Effect> shadow;
    winrt::check_hresult(dc->CreateEffect(kCLSID_D2D1Shadow, shadow.put()));
    shadow->SetValue(D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION, blur / 3.0f);
    const D2D1_COLOR_F sc = ColorFromArgb(spec.shadowArgb);
    shadow->SetValue(D2D1_SHADOW_PROP_COLOR,
                     D2D1::Vector4F(sc.r, sc.g, sc.b, sc.a));

    winrt::com_ptr<ID2D1Image> shadow_out;
    if (spec.shapeFromAlpha) {
      shadow->SetInput(0, content_bmp.get());
      shadow->GetOutput(shadow_out.put());
      D2D1_POINT_2F offset = D2D1::Point2F(m + dx, m + dy);
      dc->DrawImage(shadow_out.get(), &offset);
      dc->DrawBitmap(content_bmp.get(), D2D1::RectF(m, m, m + cw, m + ch));
    } else {
      shadow->SetInput(0, silhouette.get());
      shadow->GetOutput(shadow_out.put());
      D2D1_POINT_2F offset = D2D1::Point2F(dx, dy);
      dc->DrawImage(shadow_out.get(), &offset);
      winrt::com_ptr<ID2D1RoundedRectangleGeometry> geo;
      winrt::check_hresult(factory->CreateRoundedRectangleGeometry(rr, geo.put()));
      dc->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), geo.get()),
                    nullptr);
      dc->DrawBitmap(content_bmp.get(), D2D1::RectF(m, m, m + cw, m + ch));
      dc->PopLayer();
    }
    winrt::check_hresult(dc->EndDraw());

    const auto read_props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, pf);
    winrt::com_ptr<ID2D1Bitmap1> readback;
    winrt::check_hresult(dc->CreateBitmap(D2D1::SizeU(out_w, out_h), nullptr, 0,
                                          read_props, readback.put()));
    D2D1_POINT_2U dst = D2D1::Point2U(0, 0);
    D2D1_RECT_U src = D2D1::RectU(0, 0, out_w, out_h);
    winrt::check_hresult(readback->CopyFromBitmap(&dst, target.get(), &src));

    D2D1_MAPPED_RECT mapped{};
    winrt::check_hresult(readback->Map(D2D1_MAP_OPTIONS_READ, &mapped));
    CaptureFrame out;
    out.width = out_w;
    out.height = out_h;
    out.stride = out_w * 4;
    out.bgra.resize(static_cast<size_t>(out.stride) * out_h);
    for (uint32_t row = 0; row < out_h; ++row) {
      std::memcpy(out.bgra.data() + static_cast<size_t>(row) * out.stride,
                  mapped.bits + static_cast<size_t>(row) * mapped.pitch,
                  out.stride);
    }
    readback->Unmap();
    return out;
  } catch (...) {
    return std::nullopt;
  }
}

}  // namespace deco
