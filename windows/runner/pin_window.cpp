#include "pin_window.h"

#include <commdlg.h>
#include <d2d1effects.h>
#include <d3d11.h>
#include <dxgi.h>
#include <shellscalingapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "decoration.h"
#include "dpi_util.h"
#include "hdr_util.h"
#include "image_codec.h"
#include "utils.h"

namespace {

using winrt::com_ptr;

using deco::kCLSID_D2D1Shadow;

constexpr double kMarginLogical = 56.0;  // the vapor halo reach (logical pts)
constexpr double kMinZoom = 0.25;
constexpr double kMaxZoom = 3.0;
constexpr UINT_PTR kDwellTimer = 1;
constexpr UINT_PTR kAnimTimer = 2;
constexpr UINT kDwellMs = 1000;   // hover dwell before the reveal (owner: 1s)
constexpr UINT kAnimMs = 33;      // ~30 fps while revealed
constexpr float kRevealStep = 0.10f;  // reveal fade per tick (~0.3s)

constexpr const wchar_t kPinClassName[] = L"GLIMPR_PIN_WINDOW";
bool g_pin_class_registered = false;

// The brand cyan / blue / violet vapor colors (match macOS PinPanel).
struct Brand {
  float r, g, b;
};
constexpr Brand kBrand[3] = {
    {0.13f, 0.83f, 0.93f}, {0.38f, 0.65f, 0.98f}, {0.65f, 0.55f, 0.98f}};

com_ptr<ID3D11Device> CreateD3D() {
  com_ptr<ID3D11Device> d;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, d.put(), nullptr, nullptr))) {
    D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                      D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                      D3D11_SDK_VERSION, d.put(), nullptr, nullptr);
  }
  return d;
}

// Map a Glimpr-logical global point to physical pixels: physical = logical *
// (the containing monitor's scale). BuildDisplayDict defines logical = physical
// / scale per monitor, so this inverts it. Falls back to the primary scale.
double ResolveScaleForLogical(double lx, double ly) {
  struct Ctx {
    double lx, ly, scale;
    bool found;
  } ctx{lx, ly, 1.0, false};
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR mon, HDC, LPRECT, LPARAM lp) -> BOOL {
        auto* c = reinterpret_cast<Ctx*>(lp);
        if (c->found) return TRUE;
        MONITORINFO mi{};
        mi.cbSize = sizeof(mi);
        if (!GetMonitorInfo(mon, &mi)) return TRUE;
        double s = MonitorScale(mon);
        double l = mi.rcMonitor.left / s, t = mi.rcMonitor.top / s;
        double r = mi.rcMonitor.right / s, b = mi.rcMonitor.bottom / s;
        if (c->lx >= l && c->lx < r && c->ly >= t && c->ly < b) {
          c->scale = s;
          c->found = true;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&ctx));
  return ctx.scale;
}

// Write the pin image (straight BGRA) to the clipboard: CF_DIBV5 (alpha) + a
// registered "PNG" copy. Mirrors clipboard_channel's writer (kept local to avoid
// coupling the pin to the channel).
void WritePinToClipboard(const std::vector<uint8_t>& bgra, uint32_t w,
                         uint32_t h) {
  if (bgra.empty() || w == 0 || h == 0) return;
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
  if (!dib) return;
  if (auto* p = static_cast<uint8_t*>(GlobalLock(dib))) {
    std::memcpy(p, &bi, sizeof(bi));
    std::memcpy(p + sizeof(bi), bgra.data(), pix);
    GlobalUnlock(dib);
  }
  if (!OpenClipboard(nullptr)) {
    GlobalFree(dib);
    return;
  }
  EmptyClipboard();
  bool ok = SetClipboardData(CF_DIBV5, dib) != nullptr;
  std::vector<uint8_t> png = codec::EncodePng(bgra.data(), w, h, w * 4);
  if (!png.empty()) {
    if (HGLOBAL pg = GlobalAlloc(GMEM_MOVEABLE, png.size())) {
      if (void* pp = GlobalLock(pg)) {
        std::memcpy(pp, png.data(), png.size());
        GlobalUnlock(pg);
      }
      UINT cf_png = RegisterClipboardFormatW(L"PNG");
      if (cf_png) SetClipboardData(cf_png, pg);
    }
  }
  CloseClipboard();
  if (!ok) GlobalFree(dib);
}

}  // namespace

PinWindow::PinWindow() = default;

PinWindow::~PinWindow() {
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

int PinWindow::MarginPx() const {
  return static_cast<int>(std::lround(kMarginLogical * monitor_scale_));
}

RECT PinWindow::ImageRectInWindow() const {
  const int m = MarginPx();
  const int iw = static_cast<int>(std::lround(img_w_ * zoom_));
  const int ih = static_cast<int>(std::lround(img_h_ * zoom_));
  return RECT{m, m, m + iw, m + ih};
}

RECT PinWindow::CloseButtonRect() const {
  RECT img = ImageRectInWindow();
  const int sz = static_cast<int>(std::lround(24 * monitor_scale_));
  const int pad = static_cast<int>(std::lround(8 * monitor_scale_));
  const int x = img.right - sz - pad;
  const int y = img.top + pad;
  return RECT{x, y, x + sz, y + sz};
}

bool PinWindow::Create(const std::string& image_path,
                       std::optional<RECT> place_logical,
                       std::function<void(PinWindow*)> on_closed) {
  on_closed_ = std::move(on_closed);

  const std::wstring wpath = Utf16FromUtf8(image_path);
  if (!InitGraphics(wpath)) return false;

  // Resolve placement (physical pixels).
  int win_w, win_h, win_x, win_y;
  if (place_logical) {
    const RECT& r = *place_logical;
    monitor_scale_ = ResolveScaleForLogical(r.left, r.top);
    const int m = MarginPx();
    const int phys_x = static_cast<int>(std::lround(r.left * monitor_scale_));
    const int phys_y = static_cast<int>(std::lround(r.top * monitor_scale_));
    // The captured image pixels already equal the region's physical size, so
    // zoom 1 overlays it exactly.
    win_x = phys_x - m;
    win_y = phys_y - m;
    win_w = static_cast<int>(img_w_) + 2 * m;
    win_h = static_cast<int>(img_h_) + 2 * m;
  } else {
    POINT cur{};
    GetCursorPos(&cur);
    HMONITOR mon = MonitorFromPoint(cur, MONITOR_DEFAULTTONEAREST);
    monitor_scale_ = MonitorScale(mon);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    GetMonitorInfo(mon, &mi);
    const int m = MarginPx();
    win_w = static_cast<int>(img_w_) + 2 * m;
    win_h = static_cast<int>(img_h_) + 2 * m;
    const int cx = (mi.rcWork.left + mi.rcWork.right) / 2;
    const int cy = (mi.rcWork.top + mi.rcWork.bottom) / 2;
    win_x = cx - win_w / 2;
    win_y = cy - win_h / 2;
  }
  win_x_ = win_x;
  win_y_ = win_y;
  win_w_ = win_w;
  win_h_ = win_h;

  if (!g_pin_class_registered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = PinWindow::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kPinClassName;
    RegisterClassW(&wc);
    g_pin_class_registered = true;
  }

  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kPinClassName, L"", WS_POPUP, win_x_, win_y_, win_w_, win_h_, nullptr,
      nullptr, GetModuleHandle(nullptr), this);
  if (!hwnd_) return false;

  Render();
  ShowWindow(hwnd_, SW_SHOWNA);  // show without stealing focus
  return true;
}

bool PinWindow::InitGraphics(const std::wstring& path) {
  try {
    winrt::check_hresult(
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(wic_.put())));
    com_ptr<IWICBitmapDecoder> dec;
    if (FAILED(wic_->CreateDecoderFromFilename(path.c_str(), nullptr,
                                               GENERIC_READ,
                                               WICDecodeMetadataCacheOnLoad,
                                               dec.put()))) {
      return false;
    }
    com_ptr<IWICBitmapFrameDecode> frame;
    winrt::check_hresult(dec->GetFrame(0, frame.put()));
    // STRAIGHT BGRA -> kept for Save As / Copy (correct alpha).
    com_ptr<IWICFormatConverter> conv;
    winrt::check_hresult(wic_->CreateFormatConverter(conv.put()));
    winrt::check_hresult(conv->Initialize(
        frame.get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
        nullptr, 0.0, WICBitmapPaletteTypeCustom));
    winrt::check_hresult(conv->GetSize(&img_w_, &img_h_));
    if (img_w_ == 0 || img_h_ == 0) return false;
    bgra_.resize(static_cast<size_t>(img_w_) * 4 * img_h_);
    winrt::check_hresult(conv->CopyPixels(nullptr, img_w_ * 4,
                                          static_cast<UINT>(bgra_.size()),
                                          bgra_.data()));

    // Premultiplied copy for Direct2D drawing.
    std::vector<uint8_t> pm(bgra_.size());
    for (size_t i = 0; i + 3 < bgra_.size(); i += 4) {
      const uint32_t a = bgra_[i + 3];
      pm[i + 0] = static_cast<uint8_t>(bgra_[i + 0] * a / 255);
      pm[i + 1] = static_cast<uint8_t>(bgra_[i + 1] * a / 255);
      pm[i + 2] = static_cast<uint8_t>(bgra_[i + 2] * a / 255);
      pm[i + 3] = static_cast<uint8_t>(a);
    }

    auto d3d = CreateD3D();
    if (!d3d) return false;
    auto dxgi = d3d.as<IDXGIDevice>();
    D2D1_FACTORY_OPTIONS fo{};
    winrt::check_hresult(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                           __uuidof(ID2D1Factory1), &fo,
                                           factory_.put_void()));
    winrt::check_hresult(factory_->CreateDevice(dxgi.get(), device_.put()));
    winrt::check_hresult(device_->CreateDeviceContext(
        D2D1_DEVICE_CONTEXT_OPTIONS_NONE, dc_.put()));

    const auto pf = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                      D2D1_ALPHA_MODE_PREMULTIPLIED);
    winrt::check_hresult(dc_->CreateBitmap(
        D2D1::SizeU(img_w_, img_h_), pm.data(), img_w_ * 4,
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_NONE, pf),
        image_bitmap_.put()));
    return true;
  } catch (...) {
    return false;
  }
}

void PinWindow::Render() {
  if (!hwnd_ || !dc_) return;
  const UINT W = static_cast<UINT>(win_w_);
  const UINT H = static_cast<UINT>(win_h_);
  if (W == 0 || H == 0) return;

  try {
    const auto pf = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                      D2D1_ALPHA_MODE_PREMULTIPLIED);
    const auto target_props =
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, pf);

    RECT ir = ImageRectInWindow();
    const D2D1_RECT_F img_rect = D2D1::RectF(
        static_cast<float>(ir.left), static_cast<float>(ir.top),
        static_cast<float>(ir.right), static_cast<float>(ir.bottom));

    com_ptr<ID2D1Bitmap1> target;
    winrt::check_hresult(dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0,
                                           target_props, target.put()));

    // Vapor glow (revealed): an opaque rounded-rect silhouette of the image,
    // cast as 3 drifting/breathing colored Direct2D shadows. Skipped when the
    // pin_hover_glow setting is off (the close button still reveals).
    if (reveal_t_ > 0.01f && glow_enabled_) {
      com_ptr<ID2D1Bitmap1> sil;
      winrt::check_hresult(dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0,
                                             target_props, sil.put()));
      dc_->SetTarget(sil.get());
      dc_->BeginDraw();
      dc_->Clear(D2D1::ColorF(0, 0, 0, 0));
      com_ptr<ID2D1SolidColorBrush> white;
      dc_->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), white.put());
      dc_->FillRoundedRectangle(D2D1::RoundedRect(img_rect, 4, 4), white.get());
      winrt::check_hresult(dc_->EndDraw());

      dc_->SetTarget(target.get());
      dc_->BeginDraw();
      dc_->Clear(D2D1::ColorF(0, 0, 0, 0));
      com_ptr<ID2D1Effect> shadow;
      if (SUCCEEDED(dc_->CreateEffect(kCLSID_D2D1Shadow, shadow.put()))) {
        const double p = anim_phase_;
        for (int i = 0; i < 3; ++i) {
          const double fi = i;
          const double dx =
              (5 + fi * 1.5) * std::sin(p * 6.2831853 / (2.3 + fi * 0.7));
          const double dy =
              -(4 + fi * 1.5) * std::sin(p * 6.2831853 / (3.1 + fi * 0.5));
          const double breathe =
              0.5 + 0.5 * std::sin(p * 6.2831853 / (2.0 + fi * 0.6));
          const double radius =
              (9 + fi * 2) + breathe * 7.0;  // 9..16 (+2 per layer)
          shadow->SetValue(D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION,
                           static_cast<float>(radius * monitor_scale_ / 3.0));
          shadow->SetValue(
              D2D1_SHADOW_PROP_COLOR,
              D2D1::Vector4F(kBrand[i].r, kBrand[i].g, kBrand[i].b,
                             0.85f * reveal_t_));
          shadow->SetInput(0, sil.get());
          com_ptr<ID2D1Image> out;
          shadow->GetOutput(out.put());
          D2D1_POINT_2F off =
              D2D1::Point2F(static_cast<float>(dx * monitor_scale_),
                            static_cast<float>(dy * monitor_scale_));
          dc_->DrawImage(out.get(), &off);
        }
      }
    } else {
      dc_->SetTarget(target.get());
      dc_->BeginDraw();
      dc_->Clear(D2D1::ColorF(0, 0, 0, 0));
    }

    // The image.
    dc_->DrawBitmap(image_bitmap_.get(), img_rect);

    // Glass close button (revealed): a near-opaque light disc + a bold X.
    if (reveal_t_ > 0.01f) {
      RECT cb = CloseButtonRect();
      const D2D1_RECT_F cbr = D2D1::RectF(
          static_cast<float>(cb.left), static_cast<float>(cb.top),
          static_cast<float>(cb.right), static_cast<float>(cb.bottom));
      const float r = (cbr.bottom - cbr.top) / 2.0f;
      com_ptr<ID2D1SolidColorBrush> disc;
      const float disc_a = (close_hover_ ? 0.98f : 0.90f) * reveal_t_;
      dc_->CreateSolidColorBrush(D2D1::ColorF(0.96f, 0.96f, 0.97f, disc_a),
                                 disc.put());
      dc_->FillRoundedRectangle(D2D1::RoundedRect(cbr, r, r), disc.get());
      com_ptr<ID2D1SolidColorBrush> x;
      const float x_a = (close_hover_ ? 0.95f : 0.70f) * reveal_t_;
      dc_->CreateSolidColorBrush(D2D1::ColorF(0.15f, 0.16f, 0.20f, x_a),
                                 x.put());
      const float inset = (cbr.right - cbr.left) * 0.32f;
      const float sw = std::max(1.5f, 2.0f * static_cast<float>(monitor_scale_));
      dc_->DrawLine(D2D1::Point2F(cbr.left + inset, cbr.top + inset),
                    D2D1::Point2F(cbr.right - inset, cbr.bottom - inset),
                    x.get(), sw);
      dc_->DrawLine(D2D1::Point2F(cbr.right - inset, cbr.top + inset),
                    D2D1::Point2F(cbr.left + inset, cbr.bottom - inset),
                    x.get(), sw);
    }

    winrt::check_hresult(dc_->EndDraw());

    // Readback -> a top-down 32bpp DIB section -> UpdateLayeredWindow.
    const auto read_props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, pf);
    com_ptr<ID2D1Bitmap1> readback;
    winrt::check_hresult(dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0,
                                           read_props, readback.put()));
    D2D1_POINT_2U dst = D2D1::Point2U(0, 0);
    D2D1_RECT_U src = D2D1::RectU(0, 0, W, H);
    winrt::check_hresult(readback->CopyFromBitmap(&dst, target.get(), &src));
    D2D1_MAPPED_RECT mapped{};
    winrt::check_hresult(readback->Map(D2D1_MAP_OPTIONS_READ, &mapped));

    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = static_cast<LONG>(W);
    bmi.bmiHeader.biHeight = -static_cast<LONG>(H);  // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    HDC screen = GetDC(nullptr);
    void* bits = nullptr;
    HBITMAP dib =
        CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (dib && bits) {
      for (UINT row = 0; row < H; ++row) {
        std::memcpy(static_cast<uint8_t*>(bits) + static_cast<size_t>(row) * W * 4,
                    mapped.bits + static_cast<size_t>(row) * mapped.pitch,
                    static_cast<size_t>(W) * 4);
      }
      HDC mem = CreateCompatibleDC(screen);
      HBITMAP old = static_cast<HBITMAP>(SelectObject(mem, dib));
      POINT src_pt = {0, 0};
      SIZE size = {static_cast<LONG>(W), static_cast<LONG>(H)};
      POINT dst_pt = {win_x_, win_y_};
      BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
      UpdateLayeredWindow(hwnd_, screen, &dst_pt, &size, mem, &src_pt, 0, &bf,
                          ULW_ALPHA);
      SelectObject(mem, old);
      DeleteDC(mem);
    }
    if (dib) DeleteObject(dib);
    ReleaseDC(nullptr, screen);
    readback->Unmap();
    dc_->SetTarget(nullptr);
  } catch (...) {
    if (dc_) dc_->SetTarget(nullptr);
  }
}

void PinWindow::SetZoom(double z) {
  z = std::clamp(z, kMinZoom, kMaxZoom);
  const int m = MarginPx();
  const int new_iw = static_cast<int>(std::lround(img_w_ * z));
  const int new_ih = static_cast<int>(std::lround(img_h_ * z));
  const int new_w = new_iw + 2 * m;
  const int new_h = new_ih + 2 * m;
  // Keep the window center fixed.
  const int cx = win_x_ + win_w_ / 2;
  const int cy = win_y_ + win_h_ / 2;
  zoom_ = z;
  win_w_ = new_w;
  win_h_ = new_h;
  win_x_ = cx - new_w / 2;
  win_y_ = cy - new_h / 2;
  Render();
}

void PinWindow::Reveal(bool on) {
  revealed_ = on;
  // Ensure the animation timer runs (it drives both the drift and the fade,
  // and stops itself once fully hidden).
  if (hwnd_) SetTimer(hwnd_, kAnimTimer, kAnimMs, nullptr);
}

void PinWindow::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, 1, L"Reset Size");
  AppendMenuW(menu, MF_STRING, 2, L"Save As...");
  AppendMenuW(menu, MF_STRING, 3, L"Copy to Clipboard");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 4, L"Close Pin");
  POINT pt{};
  GetCursorPos(&pt);
  SetForegroundWindow(hwnd_);
  UINT cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
                            pt.x, pt.y, 0, hwnd_, nullptr);
  PostMessage(hwnd_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (cmd) {
    case 1: SetZoom(1.0); break;
    case 2: SaveAs(); break;
    case 3: CopyToClipboard(); break;
    case 4: ClosePin(); break;
    default: break;
  }
}

void PinWindow::SaveAs() {
  wchar_t file[MAX_PATH] = L"pin.png";
  OPENFILENAMEW ofn{};
  ofn.lStructSize = sizeof(ofn);
  ofn.hwndOwner = hwnd_;
  ofn.lpstrFilter = L"PNG Image\0*.png\0";
  ofn.lpstrFile = file;
  ofn.nMaxFile = MAX_PATH;
  ofn.lpstrDefExt = L"png";
  ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
  if (!GetSaveFileNameW(&ofn)) return;
  std::vector<uint8_t> png =
      codec::EncodePng(bgra_.data(), img_w_, img_h_, img_w_ * 4);
  if (png.empty()) return;
  HANDLE h = CreateFileW(file, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return;
  DWORD wrote = 0;
  WriteFile(h, png.data(), static_cast<DWORD>(png.size()), &wrote, nullptr);
  CloseHandle(h);
}

void PinWindow::CopyToClipboard() {
  WritePinToClipboard(bgra_, img_w_, img_h_);
}

void PinWindow::ClosePin() {
  if (hwnd_) {
    KillTimer(hwnd_, kDwellTimer);
    KillTimer(hwnd_, kAnimTimer);
    ShowWindow(hwnd_, SW_HIDE);
  }
  if (on_closed_) on_closed_(this);  // the manager destroys us
}

// static
LRESULT CALLBACK PinWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    auto* self = static_cast<PinWindow*>(cs->lpCreateParams);
    self->hwnd_ = hwnd;
  } else if (auto* self = reinterpret_cast<PinWindow*>(
                 GetWindowLongPtr(hwnd, GWLP_USERDATA))) {
    return self->MessageHandler(hwnd, message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT PinWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST: {
      // Only the image area is interactive; clicks on the transparent halo pass
      // through to whatever is beneath.
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &pt);
      RECT img = ImageRectInWindow();
      return PtInRect(&img, pt) ? HTCLIENT : HTTRANSPARENT;
    }
    case WM_MOUSEMOVE: {
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (dragging_) {
        POINT cur{};
        GetCursorPos(&cur);
        win_x_ = cur.x - drag_offset_.x;
        win_y_ = cur.y - drag_offset_.y;
        // Reposition only: a layered window retains its content, so moving
        // needs no repaint. The previous full Render() per mouse-move was a
        // whole-pin GPU->CPU readback (~35MB per event on a 4K-region pin) at
        // pointer-event rate; the reveal animation timer still repaints while
        // the glow is shown (it reads the updated win_x_/win_y_).
        SetWindowPos(hwnd, nullptr, win_x_, win_y_, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
      }
      if (!tracking_leave_) {
        TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tme);
        tracking_leave_ = true;
      }
      RECT img = ImageRectInWindow();
      if (PtInRect(&img, pt) && !revealed_ && !dwell_pending_) {
        SetTimer(hwnd, kDwellTimer, kDwellMs, nullptr);
        dwell_pending_ = true;
      }
      if (revealed_) {
        RECT cb = CloseButtonRect();
        bool over = PtInRect(&cb, pt) != 0;
        if (over != close_hover_) {
          close_hover_ = over;
          SetCursor(LoadCursor(nullptr, over ? IDC_HAND : IDC_ARROW));
          Render();
        }
      }
      return 0;
    }
    case WM_MOUSELEAVE: {
      tracking_leave_ = false;
      if (dwell_pending_) {
        KillTimer(hwnd, kDwellTimer);
        dwell_pending_ = false;
      }
      close_hover_ = false;
      Reveal(false);
      return 0;
    }
    case WM_LBUTTONDOWN: {
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (revealed_) {
        RECT cb = CloseButtonRect();
        if (PtInRect(&cb, pt)) {
          ClosePin();
          return 0;
        }
      }
      // Drag anywhere on the image (manual loop, reaches every screen edge).
      POINT cur{};
      GetCursorPos(&cur);
      drag_offset_.x = cur.x - win_x_;
      drag_offset_.y = cur.y - win_y_;
      dragging_ = true;
      SetCapture(hwnd);
      return 0;
    }
    case WM_LBUTTONUP:
      if (dragging_) {
        dragging_ = false;
        ReleaseCapture();
      }
      return 0;
    case WM_RBUTTONUP:
      ShowMenu();
      return 0;
    case WM_MOUSEWHEEL: {
      const int delta = GET_WHEEL_DELTA_WPARAM(wparam);
      // Gentle steps, clamped to 25%-300% of the original size.
      SetZoom(zoom_ * (1.0 + delta * 0.0014));
      return 0;
    }
    case WM_TIMER:
      if (wparam == kDwellTimer) {
        KillTimer(hwnd, kDwellTimer);
        dwell_pending_ = false;
        // Owner setting: the hover corona/glow. Read live (per dwell) so a
        // toggle applies on the next hover even for already-open pins,
        // mirroring macOS PinPanel.glowEnabled. When off, only the close
        // control reveals.
        glow_enabled_ = hdr::ReadPrefsBool("pin_hover_glow", true);
        Reveal(true);
        return 0;
      }
      if (wparam == kAnimTimer) {
        anim_phase_ += kAnimMs / 1000.0;
        const float target = revealed_ ? 1.0f : 0.0f;
        if (reveal_t_ < target) reveal_t_ = std::min(target, reveal_t_ + kRevealStep);
        else if (reveal_t_ > target) reveal_t_ = std::max(target, reveal_t_ - kRevealStep);
        Render();
        if (!revealed_ && reveal_t_ <= 0.0f) {
          KillTimer(hwnd, kAnimTimer);  // fully hidden; idle (static image)
        }
        return 0;
      }
      return 0;
    case WM_DESTROY:
      hwnd_ = nullptr;
      return 0;
    default:
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// ---- PinManager -----------------------------------------------------------

void PinManager::Pin(const std::string& image_path,
                     std::optional<RECT> place_logical) {
  auto pin = std::make_unique<PinWindow>();
  PinWindow* raw = pin.get();
  if (!pin->Create(image_path, place_logical, [this](PinWindow* p) {
        pins_.erase(std::remove_if(pins_.begin(), pins_.end(),
                                   [p](const std::unique_ptr<PinWindow>& u) {
                                     return u.get() == p;
                                   }),
                    pins_.end());
      })) {
    return;  // unique_ptr drops the failed pin
  }
  (void)raw;
  pins_.push_back(std::move(pin));
}
