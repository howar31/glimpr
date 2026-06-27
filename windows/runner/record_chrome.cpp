#include "record_chrome.h"

#include <d3d11.h>
#include <dxgi.h>
#include <shellscalingapi.h>
#include <windowsx.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

// NOTE on DrawText: windows.h defines DrawText -> DrawTextW, and d2d1.h is parsed
// with that macro active, so the render-target method is declared as DrawTextW.
// We therefore call dc_->DrawText(...), which the macro expands to the matching
// DrawTextW -- do NOT #undef the macro (that would leave the literal name unbound).

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011  // Win10 2004+; excludes from WGC/PrintWindow
#endif

namespace {

using winrt::com_ptr;

constexpr wchar_t kClass[] = L"GlimprRecordChrome";
constexpr UINT_PTR kTickTimer = 0xC001;
constexpr UINT kTickMs = 500;

// Strip size + paddings, in LOGICAL points (scaled by the monitor scale).
constexpr int kStripW = 320;
constexpr int kStripH = 46;
constexpr int kPad = 14;
constexpr int kBtnW = 60;
constexpr int kBtnH = 30;
constexpr int kBtnGap = 8;
constexpr int kGapBelow = 10;  // gap below the recorded rect

double MonScale(HMONITOR mon) {
  UINT dx = 96, dy = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dx, &dy))) dx = 96;
  return dx / 96.0;
}

// A layered, click-through, top-most, capture-excluded overlay at [x,y,w,h]
// (physical px), its 32bpp top-down content filled by |fill| (premultiplied
// BGRA). Used for the recorded-rect border + the other-display scrims.
HWND CreateFilledOverlay(int x, int y, int w, int h,
                         const std::function<void(uint8_t*, int, int)>& fill) {
  if (w <= 0 || h <= 0) return nullptr;
  static bool reg = false;
  static const wchar_t kOv[] = L"GlimprRecordOverlay";
  if (!reg) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kOv;
    RegisterClassW(&wc);
    reg = true;
  }
  HWND hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kOv, L"", WS_POPUP, x, y, w, h, nullptr, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!hwnd) return nullptr;
  SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = w;
  bmi.bmiHeader.biHeight = -h;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr);
  void* bits = nullptr;
  HBITMAP dib =
      CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (dib && bits) {
    std::memset(bits, 0, static_cast<size_t>(w) * h * 4);
    fill(static_cast<uint8_t*>(bits), w, h);
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP old = static_cast<HBITMAP>(SelectObject(mem, dib));
    POINT sp{0, 0};
    SIZE sz{w, h};
    POINT dp{x, y};
    BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    UpdateLayeredWindow(hwnd, screen, &dp, &sz, mem, &sp, 0, &bf, ULW_ALPHA);
    SelectObject(mem, old);
    DeleteDC(mem);
  }
  if (dib) DeleteObject(dib);
  ReleaseDC(nullptr, screen);
  return hwnd;
}

struct ScrimEnum {
  HMONITOR skip = nullptr;
  std::vector<HWND>* out = nullptr;
  const std::function<void(uint8_t*, int, int)>* fill = nullptr;
};

BOOL CALLBACK ScrimMonitorProc(HMONITOR mon, HDC, LPRECT, LPARAM lp) {
  auto* ctx = reinterpret_cast<ScrimEnum*>(lp);
  if (mon == ctx->skip) return TRUE;
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfo(mon, &mi)) return TRUE;
  HWND s = CreateFilledOverlay(
      mi.rcMonitor.left, mi.rcMonitor.top,
      mi.rcMonitor.right - mi.rcMonitor.left,
      mi.rcMonitor.bottom - mi.rcMonitor.top, *ctx->fill);
  if (s) ctx->out->push_back(s);
  return TRUE;
}

com_ptr<ID3D11Device> CreateD3D() {
  com_ptr<ID3D11Device> dev;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0};
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                                 D3D11_SDK_VERSION, dev.put(), nullptr, nullptr);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                           D3D11_SDK_VERSION, dev.put(), nullptr, nullptr);
  }
  return SUCCEEDED(hr) ? dev : nullptr;
}

}  // namespace

RecordChrome::RecordChrome() {}
RecordChrome::~RecordChrome() { Hide(); }

LRESULT CALLBACK RecordChrome::WndProc(HWND hwnd, UINT msg, WPARAM wp,
                                       LPARAM lp) noexcept {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self =
      reinterpret_cast<RecordChrome*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->MessageHandler(hwnd, msg, wp, lp);
  return DefWindowProcW(hwnd, msg, wp, lp);
}

bool RecordChrome::EnsureGraphics() {
  if (dc_) return true;
  try {
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

    winrt::check_hresult(DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(dwrite_.put())));
    const float ts = static_cast<float>(17.0 * scale_);
    winrt::check_hresult(dwrite_->CreateTextFormat(
        L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, ts, L"",
        timer_fmt_.put()));
    timer_fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    timer_fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
    const float ls = static_cast<float>(14.0 * scale_);
    winrt::check_hresult(dwrite_->CreateTextFormat(
        L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, ls, L"",
        label_fmt_.put()));
    label_fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    label_fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    return true;
  } catch (...) {
    return false;
  }
}

void RecordChrome::Layout() {
  auto S = [this](int v) { return static_cast<int>(std::lround(v * scale_)); };
  const int top = (win_h_ - S(kBtnH)) / 2;
  const int bw = S(kBtnW), bh = S(kBtnH), gap = S(kBtnGap), pad = S(kPad);
  int right = win_w_ - pad;
  stop_rc_ = {right - bw, top, right, top + bh};
  right = stop_rc_.left - gap;
  abort_rc_ = {right - bw, top, right, top + bh};
  right = abort_rc_.left - gap;
  pause_rc_ = {right - bw, top, right, top + bh};
}

void RecordChrome::Show(int64_t display_id, double x, double y, double w,
                        double h, bool border, bool scrim, Callbacks cb) {
  Hide();
  cb_ = std::move(cb);
  paused_ = false;
  paused_at_ = 0;
  paused_total_ = 0;
  hover_ = 0;
  start_ms_ = GetTickCount64();

  HMONITOR mon = reinterpret_cast<HMONITOR>(static_cast<intptr_t>(display_id));
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(mon, &mi)) {
    POINT pt{};
    GetCursorPos(&pt);
    mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfo(mon, &mi);
  }
  scale_ = MonScale(mon);
  auto S = [this](double v) { return static_cast<int>(std::lround(v * scale_)); };

  win_w_ = S(kStripW);
  win_h_ = S(kStripH);

  // Target rect in physical px (display-local logical -> monitor-global).
  const int tx = mi.rcMonitor.left + S(x);
  const int ty = mi.rcMonitor.top + S(y);
  const int tw = S(w);
  const int th = S(h);

  // Bottom-centre of the target; tuck inside if there is no room below.
  win_x_ = tx + (tw - win_w_) / 2;
  win_y_ = ty + th + S(kGapBelow);
  if (win_y_ + win_h_ > mi.rcMonitor.bottom) {
    win_y_ = ty + th - win_h_ - S(kGapBelow);
  }
  // Clamp to the monitor.
  if (win_x_ < mi.rcMonitor.left) win_x_ = mi.rcMonitor.left;
  if (win_x_ + win_w_ > mi.rcMonitor.right) win_x_ = mi.rcMonitor.right - win_w_;
  if (win_y_ < mi.rcMonitor.top) win_y_ = mi.rcMonitor.top;
  if (win_y_ + win_h_ > mi.rcMonitor.bottom)
    win_y_ = mi.rcMonitor.bottom - win_h_;

  static bool registered = false;
  if (!registered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = &RecordChrome::WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassW(&wc);
    registered = true;
  }

  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kClass, L"", WS_POPUP, win_x_, win_y_, win_w_, win_h_, nullptr, nullptr,
      GetModuleHandleW(nullptr), this);
  if (!hwnd_) return;
  // Keep the strip out of the recording (Win10 2004+; older OS shows it).
  SetWindowDisplayAffinity(hwnd_, WDA_EXCLUDEFROMCAPTURE);

  if (!EnsureGraphics()) {
    Hide();
    return;
  }
  Layout();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  Render();
  SetTimer(hwnd_, kTickTimer, kTickMs, nullptr);

  // Red outline around the recorded rect (region / window modes).
  if (border) {
    const int t = (std::max)(2, static_cast<int>(std::lround(3 * scale_)));
    auto border_fill = [t](uint8_t* p, int W, int H) {
      for (int yy = 0; yy < H; ++yy) {
        for (int xx = 0; xx < W; ++xx) {
          if (xx < t || xx >= W - t || yy < t || yy >= H - t) {
            uint8_t* q = p + (static_cast<size_t>(yy) * W + xx) * 4;
            q[0] = 0x3A;  // B  (recording red #FF453A, premultiplied A=255)
            q[1] = 0x45;  // G
            q[2] = 0xFF;  // R
            q[3] = 0xFF;  // A
          }
        }
      }
    };
    border_hwnd_ = CreateFilledOverlay(tx, ty, tw, th, border_fill);
  }

  // Dim every OTHER display (40% black premultiplied).
  if (scrim) {
    auto scrim_fill = [](uint8_t* p, int W, int H) {
      const size_t n = static_cast<size_t>(W) * H;
      for (size_t i = 0; i < n; ++i) p[i * 4 + 3] = 0x66;  // BGR stay 0 (black)
    };
    std::function<void(uint8_t*, int, int)> fill = scrim_fill;
    ScrimEnum ctx{mon, &scrim_hwnds_, &fill};
    EnumDisplayMonitors(nullptr, nullptr, &ScrimMonitorProc,
                        reinterpret_cast<LPARAM>(&ctx));
  }
}

void RecordChrome::SetPaused(bool paused) {
  if (paused == paused_ || !hwnd_) return;
  const ULONGLONG now = GetTickCount64();
  if (paused) {
    paused_at_ = now;
  } else if (paused_at_) {
    paused_total_ += now - paused_at_;
    paused_at_ = 0;
  }
  paused_ = paused;
  Render();
}

void RecordChrome::Hide() {
  if (hwnd_) {
    KillTimer(hwnd_, kTickTimer);
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  if (border_hwnd_) {
    DestroyWindow(border_hwnd_);
    border_hwnd_ = nullptr;
  }
  for (HWND s : scrim_hwnds_) {
    if (s) DestroyWindow(s);
  }
  scrim_hwnds_.clear();
}

int RecordChrome::HitTest(POINT p) const {
  auto in = [&](const RECT& r) {
    return p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom;
  };
  if (in(stop_rc_)) return 1;
  if (in(pause_rc_)) return 2;
  if (in(abort_rc_)) return 3;
  return 0;
}

LRESULT RecordChrome::MessageHandler(HWND hwnd, UINT msg, WPARAM wp,
                                     LPARAM lp) noexcept {
  switch (msg) {
    case WM_TIMER:
      if (wp == kTickTimer) {
        Render();
        return 0;
      }
      break;
    case WM_MOUSEMOVE: {
      POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      const int h = HitTest(p);
      if (h != hover_) {
        hover_ = h;
        Render();
      }
      if (!tracking_leave_) {
        TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tme);
        tracking_leave_ = true;
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      tracking_leave_ = false;
      if (hover_ != 0) {
        hover_ = 0;
        Render();
      }
      return 0;
    case WM_LBUTTONUP: {
      POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      const int h = HitTest(p);
      // Copy the callback before any potential teardown the callback triggers.
      if (h == 1) {
        if (cb_.on_stop) cb_.on_stop();
      } else if (h == 2) {
        if (cb_.on_pause_toggle) cb_.on_pause_toggle();
      } else if (h == 3) {
        if (cb_.on_abort) cb_.on_abort();
      }
      return 0;
    }
    case WM_DESTROY:
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

void RecordChrome::Render() {
  if (!hwnd_ || !dc_) return;
  const UINT W = static_cast<UINT>(win_w_), H = static_cast<UINT>(win_h_);
  if (W == 0 || H == 0) return;
  auto S = [this](double v) { return static_cast<float>(v * scale_); };

  // Elapsed (excluding paused spans).
  ULONGLONG now = GetTickCount64();
  ULONGLONG el = now - start_ms_ - paused_total_;
  if (paused_ && paused_at_) el -= (now - paused_at_);
  const long long secs = static_cast<long long>(el / 1000);
  wchar_t timer[16];
  swprintf_s(timer, L"%02lld:%02lld", secs / 60, secs % 60);

  try {
    const auto pf = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                      D2D1_ALPHA_MODE_PREMULTIPLIED);
    const auto tp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, pf);
    com_ptr<ID2D1Bitmap1> target;
    winrt::check_hresult(
        dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0, tp, target.put()));
    dc_->SetTarget(target.get());
    dc_->BeginDraw();
    dc_->Clear(D2D1::ColorF(0, 0, 0, 0));

    com_ptr<ID2D1SolidColorBrush> brush;
    dc_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0), brush.put());
    auto fill = [&](const D2D1_RECT_F& r, float rad, const D2D1_COLOR_F& c) {
      brush->SetColor(c);
      dc_->FillRoundedRectangle(D2D1::RoundedRect(r, rad, rad), brush.get());
    };

    // Near-solid dark bar.
    const float rad = S(11);
    fill(D2D1::RectF(0, 0, static_cast<float>(W), static_cast<float>(H)), rad,
         D2D1::ColorF(0x0F172A, 0.96f));

    // Recording-red dot (left).
    const float cy = H / 2.0f;
    const float dotx = S(kPad) + S(5);
    brush->SetColor(D2D1::ColorF(0xFF453A, paused_ ? 0.45f : 1.0f));
    dc_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(dotx, cy), S(5), S(5)),
                     brush.get());

    // Timer text.
    brush->SetColor(D2D1::ColorF(0xFFFFFF, 0.92f));
    const D2D1_RECT_F trc =
        D2D1::RectF(S(kPad) + S(20), 0, S(kPad) + S(20) + S(64),
                    static_cast<float>(H));
    dc_->DrawText(timer, static_cast<UINT32>(wcslen(timer)), timer_fmt_.get(),
                  trc, brush.get());

    // Buttons.
    auto draw_btn = [&](const RECT& rc, const wchar_t* label, bool red,
                        bool hover) {
      const D2D1_RECT_F r = D2D1::RectF(
          static_cast<float>(rc.left), static_cast<float>(rc.top),
          static_cast<float>(rc.right), static_cast<float>(rc.bottom));
      const float br = S(7);
      if (red) {
        fill(r, br, D2D1::ColorF(0xFF453A, hover ? 1.0f : 0.92f));
      } else if (hover) {
        fill(r, br, D2D1::ColorF(0xFFFFFF, 0.12f));
      } else {
        fill(r, br, D2D1::ColorF(0xFFFFFF, 0.06f));
      }
      brush->SetColor(red ? D2D1::ColorF(0xFFFFFF, 1.0f)
                          : D2D1::ColorF(0xFFFFFF, hover ? 0.95f : 0.75f));
      dc_->DrawText(label, static_cast<UINT32>(wcslen(label)),
                    label_fmt_.get(), r, brush.get());
    };
    draw_btn(pause_rc_, paused_ ? L"Resume" : L"Pause", false, hover_ == 2);
    draw_btn(abort_rc_, L"Abort", false, hover_ == 3);
    draw_btn(stop_rc_, L"Stop", true, hover_ == 1);

    winrt::check_hresult(dc_->EndDraw());

    // Readback -> top-down 32bpp DIB -> UpdateLayeredWindow.
    const auto rp = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, pf);
    com_ptr<ID2D1Bitmap1> readback;
    winrt::check_hresult(
        dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0, rp, readback.put()));
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
        std::memcpy(
            static_cast<uint8_t*>(bits) + static_cast<size_t>(row) * W * 4,
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
