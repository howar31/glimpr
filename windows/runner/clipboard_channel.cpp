#include "clipboard_channel.h"

#include <windows.h>
#include <wincodec.h>

#include <flutter/standard_method_codec.h>
#include <winrt/base.h>

#include <cstring>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Decode encoded image bytes (PNG/JPEG/...) to straight-alpha 32bpp BGRA.
bool DecodeToBgra(const uint8_t* data, size_t len, std::vector<uint8_t>& out,
                  uint32_t& w, uint32_t& h) {
  try {
    winrt::com_ptr<IWICImagingFactory> factory;
    winrt::check_hresult(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                          CLSCTX_INPROC_SERVER,
                                          IID_PPV_ARGS(factory.put())));
    winrt::com_ptr<IWICStream> stream;
    winrt::check_hresult(factory->CreateStream(stream.put()));
    winrt::check_hresult(stream->InitializeFromMemory(
        const_cast<BYTE*>(data), static_cast<DWORD>(len)));
    winrt::com_ptr<IWICBitmapDecoder> decoder;
    winrt::check_hresult(factory->CreateDecoderFromStream(
        stream.get(), nullptr, WICDecodeMetadataCacheOnLoad, decoder.put()));
    winrt::com_ptr<IWICBitmapFrameDecode> frame;
    winrt::check_hresult(decoder->GetFrame(0, frame.put()));
    winrt::com_ptr<IWICFormatConverter> conv;
    winrt::check_hresult(factory->CreateFormatConverter(conv.put()));
    winrt::check_hresult(conv->Initialize(
        frame.get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
        nullptr, 0.0, WICBitmapPaletteTypeCustom));
    winrt::check_hresult(conv->GetSize(&w, &h));
    out.resize(static_cast<size_t>(w) * 4 * h);
    winrt::check_hresult(conv->CopyPixels(
        nullptr, w * 4, static_cast<UINT>(out.size()), out.data()));
    return true;
  } catch (...) {
    return false;
  }
}

bool IsPng(const uint8_t* data, size_t len) {
  static const uint8_t kSig[8] = {0x89, 0x50, 0x4E, 0x47,
                                  0x0D, 0x0A, 0x1A, 0x0A};
  return len >= 8 && std::memcmp(data, kSig, 8) == 0;
}

HGLOBAL CopyToGlobal(const void* data, size_t size) {
  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!h) return nullptr;
  void* p = GlobalLock(h);
  if (!p) {
    GlobalFree(h);
    return nullptr;
  }
  std::memcpy(p, data, size);
  GlobalUnlock(h);
  return h;
}

bool WriteImageToClipboard(const uint8_t* data, size_t len) {
  std::vector<uint8_t> bgra;
  uint32_t w = 0, h = 0;
  if (!DecodeToBgra(data, len, bgra, w, h) || w == 0 || h == 0) return false;

  BITMAPV5HEADER bi{};
  bi.bV5Size = sizeof(BITMAPV5HEADER);
  bi.bV5Width = static_cast<LONG>(w);
  bi.bV5Height = -static_cast<LONG>(h);  // top-down
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;
  bi.bV5CSType = LCS_WINDOWS_COLOR_SPACE;
  bi.bV5Intent = LCS_GM_IMAGES;

  const size_t pix = static_cast<size_t>(w) * 4 * h;
  HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPV5HEADER) + pix);
  if (!dib) return false;
  {
    auto* p = static_cast<uint8_t*>(GlobalLock(dib));
    if (!p) {
      GlobalFree(dib);
      return false;
    }
    std::memcpy(p, &bi, sizeof(bi));
    std::memcpy(p + sizeof(bi), bgra.data(), pix);
    GlobalUnlock(dib);
  }

  if (!OpenClipboard(nullptr)) {
    GlobalFree(dib);
    return false;
  }
  EmptyClipboard();
  bool ok = SetClipboardData(CF_DIBV5, dib) != nullptr;
  // PNG fidelity (preserves alpha) for apps that prefer it.
  if (IsPng(data, len)) {
    if (HGLOBAL png = CopyToGlobal(data, len)) {
      UINT cf_png = RegisterClipboardFormatW(L"PNG");
      if (cf_png) SetClipboardData(cf_png, png);
    }
  }
  CloseClipboard();
  if (!ok) GlobalFree(dib);  // ownership not transferred on failure
  return ok;
}

}  // namespace

ClipboardChannel::ClipboardChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

ClipboardChannel::~ClipboardChannel() = default;

void ClipboardChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "writeImage") {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const std::vector<uint8_t>* bytes = nullptr;
    if (args) {
      auto it = args->find(EncodableValue(std::string("bytes")));
      if (it != args->end()) {
        bytes = std::get_if<std::vector<uint8_t>>(&it->second);
      }
    }
    if (!bytes || bytes->empty()) {
      result->Error("bad_args", "writeImage expects non-empty bytes");
      return;
    }
    if (WriteImageToClipboard(bytes->data(), bytes->size())) {
      result->Success(EncodableValue());
    } else {
      result->Error("clipboard_failed", "could not write image to clipboard");
    }
    return;
  }
  result->NotImplemented();
}
