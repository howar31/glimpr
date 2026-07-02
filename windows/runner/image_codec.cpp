#include "image_codec.h"

#include <objbase.h>
#include <wincodec.h>
#include <winrt/base.h>

namespace {

winrt::com_ptr<IWICImagingFactory> CreateFactory() {
  winrt::com_ptr<IWICImagingFactory> factory;
  winrt::check_hresult(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                        CLSCTX_INPROC_SERVER,
                                        IID_PPV_ARGS(factory.put())));
  return factory;
}

std::vector<uint8_t> Encode(const uint8_t* bgra, uint32_t w, uint32_t h,
                            uint32_t stride, REFGUID container, bool jpeg,
                            int quality) {
  if (!bgra || w == 0 || h == 0) return {};
  try {
    auto factory = CreateFactory();

    winrt::com_ptr<IWICBitmap> source;
    const UINT buf = stride * h;
    winrt::check_hresult(factory->CreateBitmapFromMemory(
        w, h, GUID_WICPixelFormat32bppBGRA, stride, buf,
        const_cast<BYTE*>(bgra), source.put()));

    winrt::com_ptr<IStream> stream;
    winrt::check_hresult(CreateStreamOnHGlobal(nullptr, TRUE, stream.put()));

    winrt::com_ptr<IWICBitmapEncoder> encoder;
    winrt::check_hresult(
        factory->CreateEncoder(container, nullptr, encoder.put()));
    winrt::check_hresult(
        encoder->Initialize(stream.get(), WICBitmapEncoderNoCache));

    winrt::com_ptr<IWICBitmapFrameEncode> frame;
    winrt::com_ptr<IPropertyBag2> props;
    winrt::check_hresult(encoder->CreateNewFrame(frame.put(), props.put()));
    if (jpeg && props) {
      PROPBAG2 opt{};
      opt.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
      VARIANT var{};
      var.vt = VT_R4;
      var.fltVal = static_cast<float>(quality) / 100.0f;
      props->Write(1, &opt, &var);
    }
    winrt::check_hresult(frame->Initialize(props.get()));
    winrt::check_hresult(frame->SetSize(w, h));
    WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
    winrt::check_hresult(frame->SetPixelFormat(&fmt));
    winrt::check_hresult(frame->WriteSource(source.get(), nullptr));
    winrt::check_hresult(frame->Commit());
    winrt::check_hresult(encoder->Commit());

    STATSTG stat{};
    winrt::check_hresult(stream->Stat(&stat, STATFLAG_NONAME));
    const ULONG size = static_cast<ULONG>(stat.cbSize.QuadPart);
    std::vector<uint8_t> out(size);
    LARGE_INTEGER zero{};
    winrt::check_hresult(stream->Seek(zero, STREAM_SEEK_SET, nullptr));
    ULONG read = 0;
    winrt::check_hresult(stream->Read(out.data(), size, &read));
    out.resize(read);
    return out;
  } catch (...) {
    return {};
  }
}

}  // namespace

namespace codec {

std::vector<uint8_t> EncodePng(const uint8_t* bgra, uint32_t width,
                               uint32_t height, uint32_t stride) {
  return Encode(bgra, width, height, stride, GUID_ContainerFormatPng, false, 0);
}

std::vector<uint8_t> EncodeJpeg(const uint8_t* bgra, uint32_t width,
                                uint32_t height, uint32_t stride, int quality) {
  return Encode(bgra, width, height, stride, GUID_ContainerFormatJpeg, true,
                quality);
}

std::vector<uint8_t> EncodeJxr(const uint8_t* rgba_f16, uint32_t width,
                               uint32_t height, uint32_t stride,
                               bool force_opaque) {
  if (!rgba_f16 || width == 0 || height == 0) return {};
  try {
    auto factory = CreateFactory();

    // Plain captures force alpha opaque (fp16 1.0) on a copy -- WGC window
    // captures carry real alpha, but the HDR file mirrors the SDR encode's
    // opaque policy. The HDR compositor keeps its real (mask) alpha instead.
    std::vector<uint8_t> opaque(rgba_f16,
                                rgba_f16 + static_cast<size_t>(stride) * height);
    if (force_opaque) {
      auto* px = reinterpret_cast<uint16_t*>(opaque.data());
      const size_t count = static_cast<size_t>(width) * height;
      for (size_t i = 0; i < count; ++i) px[i * 4 + 3] = 0x3C00;  // 1.0h
    }

    winrt::com_ptr<IWICBitmap> source;
    winrt::check_hresult(factory->CreateBitmapFromMemory(
        width, height, GUID_WICPixelFormat64bppRGBAHalf, stride,
        static_cast<UINT>(opaque.size()), opaque.data(), source.put()));

    winrt::com_ptr<IStream> stream;
    winrt::check_hresult(CreateStreamOnHGlobal(nullptr, TRUE, stream.put()));

    winrt::com_ptr<IWICBitmapEncoder> encoder;
    winrt::check_hresult(factory->CreateEncoder(GUID_ContainerFormatWmp,
                                                nullptr, encoder.put()));
    winrt::check_hresult(
        encoder->Initialize(stream.get(), WICBitmapEncoderNoCache));

    winrt::com_ptr<IWICBitmapFrameEncode> frame;
    winrt::com_ptr<IPropertyBag2> props;
    winrt::check_hresult(encoder->CreateNewFrame(frame.put(), props.put()));
    winrt::check_hresult(frame->Initialize(props.get()));
    winrt::check_hresult(frame->SetSize(width, height));
    WICPixelFormatGUID fmt = GUID_WICPixelFormat64bppRGBAHalf;
    winrt::check_hresult(frame->SetPixelFormat(&fmt));
    if (!IsEqualGUID(fmt, GUID_WICPixelFormat64bppRGBAHalf)) return {};
    winrt::check_hresult(frame->WriteSource(source.get(), nullptr));
    winrt::check_hresult(frame->Commit());
    winrt::check_hresult(encoder->Commit());

    STATSTG stat{};
    winrt::check_hresult(stream->Stat(&stat, STATFLAG_NONAME));
    const ULONG size = static_cast<ULONG>(stat.cbSize.QuadPart);
    std::vector<uint8_t> out(size);
    LARGE_INTEGER zero{};
    winrt::check_hresult(stream->Seek(zero, STREAM_SEEK_SET, nullptr));
    ULONG read = 0;
    winrt::check_hresult(stream->Read(out.data(), size, &read));
    out.resize(read);
    return out;
  } catch (...) {
    return {};
  }
}

}  // namespace codec
