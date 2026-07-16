#include "clipboard_channel.h"

#include <windows.h>
#include <shellapi.h>
#include <wincodec.h>

#include <flutter/standard_method_codec.h>
#include <winrt/base.h>

#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "utils.h"

#include "clipboard_dib.h"
#include "image_codec.h"
#include "perf_log.h"

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
  const bool is_png = IsPng(data, len);
  return clip::WriteBgraToClipboard(bgra.data(), w, h, w * 4,
                                    is_png ? data : nullptr,
                                    is_png ? len : 0);
}

// Wrap a packed DIB (BITMAPINFOHEADER/BITMAPV5HEADER + optional masks + color
// table + pixels, as held by CF_DIB/CF_DIBV5) in a 14-byte BITMAPFILEHEADER so
// the WIC BMP decoder can read it. The file header is built by hand (the
// BITMAPFILEHEADER struct pads to 16 bytes).
bool BuildBmpFromDib(const uint8_t* dib, size_t dib_size,
                     std::vector<uint8_t>& out) {
  if (dib_size < 40) return false;  // smaller than a BITMAPINFOHEADER
  uint32_t bi_size = 0, bi_compression = 0, bi_clr_used = 0;
  uint16_t bi_bit_count = 0;
  std::memcpy(&bi_size, dib + 0, 4);
  std::memcpy(&bi_bit_count, dib + 14, 2);
  std::memcpy(&bi_compression, dib + 16, 4);
  std::memcpy(&bi_clr_used, dib + 32, 4);

  uint32_t color_table = 0;
  if (bi_bit_count <= 8) {
    const uint32_t n = bi_clr_used ? bi_clr_used : (1u << bi_bit_count);
    color_table = n * 4;
  }
  // BI_BITFIELDS (3) on a v3 header stores 3 DWORD masks after the header; a v5
  // header (>= 56 bytes) carries the masks inside the header itself.
  uint32_t masks = (bi_compression == 3 /*BI_BITFIELDS*/ && bi_size == 40)
                       ? 12u
                       : 0u;
  const uint32_t off_bits = 14 + bi_size + color_table + masks;

  out.resize(14 + dib_size);
  out[0] = 'B';
  out[1] = 'M';
  const uint32_t bf_size = static_cast<uint32_t>(14 + dib_size);
  std::memcpy(&out[2], &bf_size, 4);
  const uint32_t reserved = 0;
  std::memcpy(&out[6], &reserved, 4);
  std::memcpy(&out[10], &off_bits, 4);
  std::memcpy(&out[14], dib, dib_size);
  return true;
}

// The clipboard's image as PNG bytes: prefer the registered "PNG" format
// (lossless, alpha-preserving), else a DIB re-encoded through WIC. Empty = no
// image. Assumes the clipboard is already open.
std::vector<uint8_t> ReadImageFromOpenClipboard() {
  std::vector<uint8_t> out;

  UINT cf_png = RegisterClipboardFormatW(L"PNG");
  if (cf_png && IsClipboardFormatAvailable(cf_png)) {
    if (HANDLE h = GetClipboardData(cf_png)) {
      if (void* p = GlobalLock(h)) {
        const SIZE_T n = GlobalSize(h);
        const auto* b = static_cast<const uint8_t*>(p);
        out.assign(b, b + n);
        GlobalUnlock(h);
      }
    }
  }

  if (out.empty()) {
    UINT fmt = 0;
    if (IsClipboardFormatAvailable(CF_DIBV5)) {
      fmt = CF_DIBV5;
    } else if (IsClipboardFormatAvailable(CF_DIB)) {
      fmt = CF_DIB;
    }
    if (fmt) {
      if (HANDLE h = GetClipboardData(fmt)) {
        if (void* p = GlobalLock(h)) {
          const SIZE_T dib_size = GlobalSize(h);
          std::vector<uint8_t> bmp;
          if (BuildBmpFromDib(static_cast<const uint8_t*>(p), dib_size, bmp)) {
            std::vector<uint8_t> bgra;
            uint32_t w = 0, hh = 0;
            if (DecodeToBgra(bmp.data(), bmp.size(), bgra, w, hh) && w && hh) {
              out = codec::EncodePng(bgra.data(), w, hh, w * 4);
            }
          }
          GlobalUnlock(h);
        }
      }
    }
  }
  return out;
}

}  // namespace

namespace clip {

bool WriteBgraToClipboard(const uint8_t* bgra, uint32_t w, uint32_t h,
                          uint32_t stride, const uint8_t* png,
                          size_t png_len) {
  if (!bgra || w == 0 || h == 0) return false;

  // A FULLY OPAQUE image advertises NO alpha: write a classic bottom-up 32bpp
  // CF_DIB (the system synthesizes CF_DIBV5 with a zero alpha mask and
  // CF_BITMAP) and no PNG format -- the same clipboard surface as Windows'
  // own screenshots. Alpha-aware consumers (LINE et al) matte/halo an image
  // whose clipboard advertises an alpha channel, even when every pixel is
  // opaque; native screenshots never trigger that. Images with real
  // transparency (decorated captures) keep the alpha-carrying DIBV5 + PNG
  // path below -- flatten-to-white there is inherent to the target app.
  if (clipdib::AllOpaque(bgra, w, h, stride)) {
    HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, clipdib::OpaqueDibSize(w, h));
    if (!dib) return false;
    {
      auto* p = static_cast<uint8_t*>(GlobalLock(dib));
      if (!p) {
        GlobalFree(dib);
        return false;
      }
      clipdib::WriteOpaqueDib(p, bgra, w, h, stride);
      GlobalUnlock(dib);
    }
    if (!OpenClipboard(nullptr)) {
      GlobalFree(dib);
      return false;
    }
    EmptyClipboard();
    const bool ok = SetClipboardData(CF_DIB, dib) != nullptr;
    CloseClipboard();
    if (!ok) GlobalFree(dib);
    return ok;
  }

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

  const size_t row = static_cast<size_t>(w) * 4;
  const size_t pix = row * h;
  HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPV5HEADER) + pix);
  if (!dib) return false;
  {
    auto* p = static_cast<uint8_t*>(GlobalLock(dib));
    if (!p) {
      GlobalFree(dib);
      return false;
    }
    std::memcpy(p, &bi, sizeof(bi));
    uint8_t* dst = p + sizeof(bi);
    if (stride == row) {
      std::memcpy(dst, bgra, pix);
    } else {
      for (uint32_t y = 0; y < h; ++y) {
        std::memcpy(dst + static_cast<size_t>(y) * row,
                    bgra + static_cast<size_t>(y) * stride, row);
      }
    }
    GlobalUnlock(dib);
  }

  if (!OpenClipboard(nullptr)) {
    GlobalFree(dib);
    return false;
  }
  EmptyClipboard();
  bool ok = SetClipboardData(CF_DIBV5, dib) != nullptr;
  // PNG fidelity (preserves alpha) for apps that prefer it.
  if (png && png_len) {
    if (HGLOBAL hpng = CopyToGlobal(png, png_len)) {
      UINT cf_png = RegisterClipboardFormatW(L"PNG");
      if (cf_png) SetClipboardData(cf_png, hpng);
    }
  }
  CloseClipboard();
  if (!ok) GlobalFree(dib);  // ownership not transferred on failure
  return ok;
}

}  // namespace clip

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
    const bool ok = WriteImageToClipboard(bytes->data(), bytes->size());
    perf::Mark(ok ? "clipboardDone ok=1" : "clipboardDone ok=0");
    if (ok) {
      result->Success(EncodableValue());
    } else {
      result->Error("clipboard_failed", "could not write image to clipboard");
    }
    return;
  }
  if (call.method_name() == "readImage") {
    std::vector<uint8_t> png;
    if (OpenClipboard(nullptr)) {
      png = ReadImageFromOpenClipboard();
      CloseClipboard();
    }
    if (png.empty()) {
      result->Success(EncodableValue());  // null -> Dart clipboardReadImage null
    } else {
      result->Success(EncodableValue(std::move(png)));
    }
    return;
  }
  if (call.method_name() == "readFilePath") {
    // The first copied FILE's path (an Explorer copy puts CF_HDROP on the
    // clipboard), or null. The GIF editor's clipboard-open uses this.
    std::string path;
    if (OpenClipboard(nullptr)) {
      if (HANDLE h = GetClipboardData(CF_HDROP)) {
        if (auto* drop = static_cast<HDROP>(GlobalLock(h))) {
          const UINT len = DragQueryFileW(drop, 0, nullptr, 0);
          if (len > 0) {
            std::wstring wide(len + 1, L'\0');
            if (DragQueryFileW(drop, 0, wide.data(), len + 1) > 0) {
              wide.resize(len);
              path = Utf8FromUtf16(wide);
            }
          }
          GlobalUnlock(h);
        }
      }
      CloseClipboard();
    }
    if (path.empty()) {
      result->Success(EncodableValue());
    } else {
      result->Success(EncodableValue(path));
    }
    return;
  }
  result->NotImplemented();
}
