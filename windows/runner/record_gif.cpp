#include "record_gif.h"

#include <wincodec.h>

#include <algorithm>

#include "com_ptr_lite.h"

struct GifSink::Impl {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  bool open = false;
};

GifSink::GifSink() : impl_(std::make_unique<Impl>()) {}
GifSink::~GifSink() {}

bool GifSink::Open(const std::wstring& path, uint32_t max_long_side) {
  max_long_side_ = max_long_side ? max_long_side : 1024;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(impl_->factory.put())))) {
    return false;
  }
  if (FAILED(impl_->factory->CreateStream(impl_->stream.put()))) return false;
  if (FAILED(impl_->stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE))) {
    return false;
  }
  if (FAILED(impl_->factory->CreateEncoder(GUID_ContainerFormatGif, nullptr,
                                           impl_->encoder.put()))) {
    return false;
  }
  if (FAILED(impl_->encoder->Initialize(impl_->stream.get(),
                                        WICBitmapEncoderNoCache))) {
    return false;
  }

  // Application extension for an infinite loop (NETSCAPE2.0). Best-effort: a GIF
  // that does not loop is still valid, so failures here are ignored.
  ComPtr<IWICMetadataQueryWriter> meta;
  if (SUCCEEDED(impl_->encoder->GetMetadataQueryWriter(meta.put())) && meta) {
    PROPVARIANT app;
    PropVariantInit(&app);
    app.vt = VT_UI1 | VT_VECTOR;
    const char kApp[] = "NETSCAPE2.0";
    app.caub.cElems = 11;
    app.caub.pElems = reinterpret_cast<UCHAR*>(const_cast<char*>(kApp));
    meta->SetMetadataByName(L"/appext/Application", &app);
    // PropVariantClear would free pElems we do not own -> just reset the struct.
    PropVariantInit(&app);

    PROPVARIANT data;
    PropVariantInit(&data);
    data.vt = VT_UI1 | VT_VECTOR;
    UCHAR loop[] = {0x03, 0x01, 0x00, 0x00};  // sub-block: loop forever
    data.caub.cElems = 4;
    data.caub.pElems = loop;
    meta->SetMetadataByName(L"/appext/Data", &data);
    PropVariantInit(&data);
  }

  impl_->open = true;
  return true;
}

bool GifSink::AddFrame(const uint8_t* bgra, uint32_t width, uint32_t height,
                       uint32_t stride, uint32_t delay_cs) {
  if (!impl_->open || width == 0 || height == 0) return false;

  ComPtr<IWICBitmap> bmp;
  if (FAILED(impl_->factory->CreateBitmapFromMemory(
          width, height, GUID_WICPixelFormat32bppBGRA, stride,
          stride * height, const_cast<BYTE*>(bgra), bmp.put()))) {
    return false;
  }

  // Downscale to the long-side ceiling (Fant for quality).
  uint32_t dw = width, dh = height;
  const uint32_t longest = (std::max)(width, height);
  if (longest > max_long_side_) {
    const double r = static_cast<double>(max_long_side_) / longest;
    dw = (std::max)(1u, static_cast<uint32_t>(width * r));
    dh = (std::max)(1u, static_cast<uint32_t>(height * r));
  }
  IWICBitmapSource* source = bmp.get();
  ComPtr<IWICBitmapScaler> scaler;
  if (dw != width || dh != height) {
    if (SUCCEEDED(impl_->factory->CreateBitmapScaler(scaler.put())) &&
        SUCCEEDED(scaler->Initialize(bmp.get(), dw, dh,
                                     WICBitmapInterpolationModeFant))) {
      source = scaler.get();
    }
  }

  // A per-frame 256-colour palette computed from the source.
  ComPtr<IWICPalette> palette;
  if (FAILED(impl_->factory->CreatePalette(palette.put()))) return false;
  if (FAILED(palette->InitializeFromBitmap(source, 256, FALSE))) return false;

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (FAILED(impl_->encoder->CreateNewFrame(frame.put(), props.put()))) {
    return false;
  }
  if (FAILED(frame->Initialize(props.get()))) return false;
  if (FAILED(frame->SetSize(dw, dh))) return false;
  WICPixelFormatGUID fmt = GUID_WICPixelFormat8bppIndexed;
  frame->SetPixelFormat(&fmt);
  frame->SetPalette(palette.get());

  // Per-frame delay (centiseconds) + leave the canvas (disposal = none).
  ComPtr<IWICMetadataQueryWriter> meta;
  if (SUCCEEDED(frame->GetMetadataQueryWriter(meta.put())) && meta) {
    PROPVARIANT delay;
    PropVariantInit(&delay);
    delay.vt = VT_UI2;
    delay.uiVal = static_cast<USHORT>(delay_cs ? delay_cs : 1);
    meta->SetMetadataByName(L"/grctlext/Delay", &delay);
    PropVariantClear(&delay);
  }

  if (FAILED(frame->WriteSource(source, nullptr))) return false;
  if (FAILED(frame->Commit())) return false;
  return true;
}

bool GifSink::Finish() {
  if (!impl_->open || !impl_->encoder) return false;
  impl_->open = false;
  return SUCCEEDED(impl_->encoder->Commit());
}
