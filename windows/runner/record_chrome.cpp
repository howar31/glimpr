#include "record_chrome.h"

#include <d2d1effects.h>
#include <d3d11.h>
#include <dwmapi.h>
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

// CLSID_D2D1GaussianBlur is declared but not defined by the SDK import libs
// (same as CLSID_D2D1Shadow in decoration.cpp) -- define the GUID value locally
// under our own name to avoid the unresolved-external link error.
const GUID kCLSID_GaussianBlur = {
    0x1feb6d69, 0x2fe6, 0x4ac9, {0x8c, 0x58, 0x1d, 0x7f, 0x93, 0xe7, 0xa6, 0xa5}};

constexpr UINT_PTR kTickTimer = 0xC001;
constexpr UINT kTickMs = 50;       // ~20 fps: smooth dot breath (idle while paused)
constexpr UINT kDetailMs = 500;    // size/frames readout poll throttle
constexpr UINT_PTR kCdTimer = 0xC002;
constexpr int kCdPanel = 132;  // countdown HUD square (logical points)

// Strip height + paddings, in LOGICAL points (scaled by the monitor scale). The
// strip WIDTH and the per-button widths are computed at Show time from the
// measured columns / localized labels (macOS sizes each button to its longest
// label state).
constexpr int kStripH = 46;
constexpr int kPad = 14;
constexpr int kBtnH = 30;
constexpr int kBtnGap = 10;    // gap between Pause / Abort / Finish (macOS)
constexpr int kBtnPadGhost = 14;  // h-padding inside a ghost button (Pause/Abort)
constexpr int kBtnPadAccent = 16; // h-padding inside the Finish accent button
constexpr int kGapBelow = 10;  // gap below the recorded rect

double MonScale(HMONITOR mon) {
  UINT dx = 96, dy = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dx, &dy))) dx = 96;
  return dx / 96.0;
}

// The app-content theme (mirrors the editor/overlay windows + tray): HKCU
// Personalize\AppsUseLightTheme. True = light. The strip follows it like the
// macOS strip follows the system appearance; the scrims/border/countdown stay
// dark in both (matching macOS RecordingDesign).
bool AppUsesLightTheme() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", 0,
          KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;  // default dark
  }
  DWORD value = 0, size = sizeof(value), type = 0;
  const LONG r = RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, &type,
                                  reinterpret_cast<LPBYTE>(&value), &size);
  RegCloseKey(key);
  return r == ERROR_SUCCESS && type == REG_DWORD && value != 0;
}

// A layered, click-through, top-most, capture-excluded overlay at [x,y,w,h]
// (physical px), its 32bpp top-down content filled by |fill| (premultiplied
// BGRA). Used for the recorded-rect border + the other-display scrims.
constexpr wchar_t kOverlayClass[] = L"GlimprRecordOverlay";

// Register the shared click-through overlay window class once (border + scrims).
void EnsureOverlayClass() {
  static bool reg = false;
  if (reg) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kOverlayClass;
  RegisterClassW(&wc);
  reg = true;
}

HWND CreateFilledOverlay(int x, int y, int w, int h,
                         const std::function<void(uint8_t*, int, int)>& fill) {
  if (w <= 0 || h <= 0) return nullptr;
  EnsureOverlayClass();
  HWND hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kOverlayClass, L"", WS_POPUP, x, y, w, h, nullptr, nullptr,
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

// A uniform translucent-black, click-through, top-most, capture-excluded scrim
// window. Unlike CreateFilledOverlay (per-pixel DIB), the alpha is uniform via
// SetLayeredWindowAttributes, so it can be moved/resized cheaply with a plain
// SetWindowPos -- used for the FOUR outside-rect dim edges, which must track a
// moving window at ~20 Hz (window-follow) without re-rasterizing a full-screen
// punch each frame.
constexpr wchar_t kUniformScrimClass[] = L"GlimprRecordScrim";

void EnsureUniformScrimClass() {
  static bool reg = false;
  if (reg) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kUniformScrimClass;
  wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&wc);
  reg = true;
}

// Create a uniform-alpha scrim window (hidden until first positioned). [alpha] is
// 0..255 (0x66 = ~40%, matching the per-pixel scrims). Position via SetWindowPos.
HWND CreateUniformScrim(BYTE alpha) {
  EnsureUniformScrimClass();
  HWND hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kUniformScrimClass, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!hwnd) return nullptr;
  SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
  return hwnd;
}

// Position a uniform scrim window to [r] (physical, global); hide it when empty.
void PlaceScrim(HWND hwnd, const RECT& r) {
  if (!hwnd) return;
  const int w = r.right - r.left, h = r.bottom - r.top;
  if (w <= 0 || h <= 0) {
    ShowWindow(hwnd, SW_HIDE);
    return;
  }
  SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top, w, h,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
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

void RecordChrome::EnsureClass() {
  static bool reg = false;
  if (reg) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = &RecordChrome::WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kClass;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  RegisterClassW(&wc);
  reg = true;
}

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
    // Single-line readouts: NEVER wrap. The rect is the full strip height, so any
    // string a hair wider than its reserved column would otherwise wrap to a
    // second line (the "00:04 line-wrap"). Clip instead (the columns reserve the
    // worst-case width, so nothing actually clips).
    timer_fmt_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    const float ls = static_cast<float>(13.5 * scale_);  // macOS StripButton font
    winrt::check_hresult(dwrite_->CreateTextFormat(
        L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, ls, L"",
        label_fmt_.put()));
    label_fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    label_fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    label_fmt_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    // Same font, LEADING-aligned: the Finish button's label sits right of its
    // stop-square glyph (the pair centered as a group).
    winrt::check_hresult(dwrite_->CreateTextFormat(
        L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, ls, L"",
        btn_lead_fmt_.put()));
    btn_lead_fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    btn_lead_fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
    btn_lead_fmt_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);

    // The file-size / frame-count readout (macOS strip's dim sizeLabel): a touch
    // smaller than the timer, right-aligned so the value hugs the divider.
    const float ss = static_cast<float>(13.5 * scale_);
    winrt::check_hresult(dwrite_->CreateTextFormat(
        L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, ss, L"",
        size_fmt_.put()));
    size_fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    size_fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_TRAILING);
    size_fmt_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    return true;
  } catch (...) {
    return false;
  }
}

float RecordChrome::MeasureWidth(IDWriteTextFormat* fmt, const wchar_t* s) {
  if (!dwrite_ || !fmt || !s) return 0.0f;
  com_ptr<IDWriteTextLayout> layout;
  if (FAILED(dwrite_->CreateTextLayout(s, static_cast<UINT32>(wcslen(s)), fmt,
                                       4096.0f, 256.0f, layout.put()))) {
    return 0.0f;
  }
  DWRITE_TEXT_METRICS m{};
  if (FAILED(layout->GetMetrics(&m))) return 0.0f;
  return m.widthIncludingTrailingWhitespace;
}

void RecordChrome::Layout() {
  auto S = [this](int v) { return static_cast<int>(std::lround(v * scale_)); };
  const int bh = S(kBtnH);
  const int top = (win_h_ - bh) / 2;
  const int gap = S(kBtnGap), pad = S(kPad);
  // Right-aligned: Finish (widest, accent), Abort, Pause -- each its own width.
  int right = win_w_ - pad;
  stop_rc_ = {right - stop_w_, top, right, top + bh};
  right = stop_rc_.left - gap;
  abort_rc_ = {right - abort_w_, top, right, top + bh};
  right = abort_rc_.left - gap;
  pause_rc_ = {right - pause_w_, top, right, top + bh};
}

void RecordChrome::Show(int64_t display_id, double x, double y, double w,
                        double h, bool border, bool scrim, int max_duration_sec,
                        bool gif, const std::string& output_path,
                        std::function<int()> frame_count, Callbacks cb,
                        HWND follow) {
  TearStrip();  // tear only the strip + countdown HUD; KEEP the frame if it is
                // already up from the countdown (seamless countdown -> record)
  cb_ = std::move(cb);
  paused_ = false;
  paused_at_ = 0;
  paused_total_ = 0;
  hover_ = 0;
  max_duration_sec_ = max_duration_sec;
  gif_ = gif;
  frame_count_ = std::move(frame_count);
  follow_hwnd_ = follow;     // window mode: track the moving/resized window
  strip_detached_ = false;   // the strip follows until the user drags it
  dragging_ = false;
  abort_armed_ = false;
  abort_arm_ms_ = 0;
  start_ms_ = GetTickCount64();
  light_ = AppUsesLightTheme();
  last_detail_.clear();
  last_detail_ms_ = 0;

  // Widen the (UTF-8) output path once for the mp4 on-disk size poll.
  out_path_w_.clear();
  if (!output_path.empty()) {
    int n = MultiByteToWideChar(CP_UTF8, 0, output_path.c_str(), -1, nullptr, 0);
    if (n > 0) {
      out_path_w_.resize(static_cast<size_t>(n - 1), L'\0');
      MultiByteToWideChar(CP_UTF8, 0, output_path.c_str(), -1, out_path_w_.data(),
                          n);
    }
  }

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

  // The D2D/DWrite graphics (text formats) must exist before measuring the
  // readout columns; it has no window dependency.
  if (!EnsureGraphics()) {
    Hide();
    return;
  }

  // Reserve the timer + size-readout columns (physical px) from their worst-case
  // strings, like the macOS strip: the size value grows (MB / 5-digit frame
  // count) and the timer gains "/ total" under auto-stop. Then size the strip to
  // fit dot + timer + size + divider + Pause + Abort + Stop.
  const wchar_t* timer_seed = max_duration_sec_ > 0 ? L"00:00 / 00:00" : L"00:00";
  timer_w_ = static_cast<int>(
      std::ceil(MeasureWidth(timer_fmt_.get(), timer_seed)));
  const std::wstring frames_seed = L"99999 " + labels_.frames;
  size_w_ = static_cast<int>(std::ceil((std::max)(
      MeasureWidth(size_fmt_.get(), L"9999.9 MB"),
      MeasureWidth(size_fmt_.get(), frames_seed.c_str()))));
  timer_x_ = S(kPad) + S(20);
  size_x_ = timer_x_ + timer_w_ + S(12);
  div_x_ = size_x_ + size_w_ + S(12);
  // Each button fits the wider of its two label states (Pause/Resume,
  // Abort/Confirm?), like macOS; Finish adds the stop-square glyph span.
  auto ghost_w = [&](const std::wstring& a, const std::wstring& b) {
    const float w = (std::max)(MeasureWidth(label_fmt_.get(), a.c_str()),
                               MeasureWidth(label_fmt_.get(), b.c_str()));
    return S(kBtnPadGhost) * 2 + static_cast<int>(std::ceil(w));
  };
  pause_w_ = ghost_w(labels_.pause, labels_.resume);
  abort_w_ = ghost_w(labels_.abort, labels_.confirm);
  const int glyph_span = S(12) + S(7);  // stop-square box + gap to the label
  stop_w_ = S(kBtnPadAccent) * 2 + glyph_span +
            static_cast<int>(
                std::ceil(MeasureWidth(label_fmt_.get(), labels_.finish.c_str())));
  const int btn_cluster = pause_w_ + abort_w_ + stop_w_ + S(kBtnGap) * 2;
  win_w_ = div_x_ + (std::max)(1, S(1)) + S(14) + btn_cluster + S(kPad);
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

  // Show the recorded-rect frame (border + outside-rect scrim + other-display
  // scrims) BEFORE the strip so they stack BENEATH it. No-op when the frame is
  // already up from the countdown (frame_up_), so it stays seamless across the
  // countdown -> recording transition (macOS shows the frame during countdown).
  CreateFrameOverlays(mon, mi, x, y, w, h, border, scrim);

  EnsureClass();

  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kClass, L"", WS_POPUP, win_x_, win_y_, win_w_, win_h_, nullptr, nullptr,
      GetModuleHandleW(nullptr), this);
  if (!hwnd_) return;
  // Keep the strip out of the recording (Win10 2004+; older OS shows it).
  SetWindowDisplayAffinity(hwnd_, WDA_EXCLUDEFROMCAPTURE);

  Layout();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  Render();
  SetTimer(hwnd_, kTickTimer, kTickMs, nullptr);
}

void RecordChrome::CreateFrameOverlays(HMONITOR mon, const MONITORINFO& mi,
                                       double x, double y, double w, double h,
                                       bool border, bool scrim) {
  if (frame_up_) return;  // already shown (e.g. created for the countdown)
  frame_up_ = true;
  auto S = [this](double v) { return static_cast<int>(std::lround(v * scale_)); };
  const int tx = mi.rcMonitor.left + S(x);
  const int ty = mi.rcMonitor.top + S(y);
  const int tw = S(w);
  const int th = S(h);
  const RECT rec_px{tx, ty, tx + tw, ty + th};
  follow_px_ = rec_px;
  follow_border_ = border;

  // Region/window modes: dim everything OUTSIDE the recorded rect on the
  // RECORDING display too (macOS RecordingFrameView punches the rect out of a
  // full-display dim). Implemented as FOUR uniform dim edges (top/bottom/left/
  // right) rather than a single per-pixel punch, so a followed window's move is a
  // cheap SetWindowPos (LayoutScrim) instead of re-rasterizing a full-display
  // bitmap each frame. Click-through + capture-excluded; the red border on top
  // covers the inner cut edge.
  if (border && scrim) {
    for (HWND& s : inrect_scrim_) {
      if (!s) s = CreateUniformScrim(0x66);
    }
    LayoutScrim(rec_px);
  }

  // Red rounded edge + glow + viewfinder corner brackets around the recorded
  // rect (region / window modes), faithful to the macOS RecordingFrameView.
  if (border) {
    ShowBorder(tx, ty, tw, th);
    border_rw_ = tw;
    border_rh_ = th;
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

void RecordChrome::LayoutScrim(const RECT& r) {
  if (!inrect_scrim_[0]) return;  // no outside-rect scrim (display mode / none)
  HMONITOR mon = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfo(mon, &mi)) return;
  const RECT m = mi.rcMonitor;
  // Clamp the clear hole to the monitor so the edges never invert.
  RECT hole = r;
  if (hole.left < m.left) hole.left = m.left;
  if (hole.top < m.top) hole.top = m.top;
  if (hole.right > m.right) hole.right = m.right;
  if (hole.bottom > m.bottom) hole.bottom = m.bottom;
  PlaceScrim(inrect_scrim_[0], {m.left, m.top, m.right, hole.top});          // top
  PlaceScrim(inrect_scrim_[1], {m.left, hole.bottom, m.right, m.bottom});    // bottom
  PlaceScrim(inrect_scrim_[2], {m.left, hole.top, hole.left, hole.bottom});  // left
  PlaceScrim(inrect_scrim_[3],
             {hole.right, hole.top, m.right, hole.bottom});  // right
}

void RecordChrome::Reframe(const RECT& r) {
  follow_px_ = r;
  const int tw = r.right - r.left, th = r.bottom - r.top;
  // Outside-rect dim edges FIRST: each PlaceScrim re-raises to the top of the
  // topmost band, so the border / strip / countdown must be re-asserted ABOVE
  // them afterwards (last SetWindowPos(HWND_TOPMOST) wins the top).
  LayoutScrim(r);
  // Border above the scrims: a pure move is a cheap SetWindowPos (also re-raises
  // it); a resize re-renders it (ShowBorder shows it on top).
  if (follow_border_) {
    const int M = (std::max)(8, static_cast<int>(std::lround(20 * scale_)));
    if (border_hwnd_ && tw == border_rw_ && th == border_rh_) {
      SetWindowPos(border_hwnd_, HWND_TOPMOST, r.left - M, r.top - M, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE);
    } else {
      if (border_hwnd_) {
        DestroyWindow(border_hwnd_);
        border_hwnd_ = nullptr;
      }
      ShowBorder(r.left, r.top, tw, th);
      border_rw_ = tw;
      border_rh_ = th;
    }
  }
  // Strip: re-home to the rect's bottom-centre until the user drags it (macOS
  // detaches on first manual drag). Render() (driven by the tick) repaints it at
  // the new win_x_/win_y_; here we just keep it stacked ABOVE the scrims.
  HMONITOR mon = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (hwnd_ && !strip_detached_ && GetMonitorInfo(mon, &mi)) {
    const int gap = static_cast<int>(std::lround(kGapBelow * scale_));
    win_x_ = r.left + (tw - win_w_) / 2;
    win_y_ = r.bottom + gap;
    if (win_y_ + win_h_ > mi.rcMonitor.bottom) win_y_ = r.top - win_h_ - gap;
    if (win_x_ < mi.rcMonitor.left) win_x_ = mi.rcMonitor.left;
    if (win_x_ + win_w_ > mi.rcMonitor.right) win_x_ = mi.rcMonitor.right - win_w_;
    if (win_y_ < mi.rcMonitor.top) win_y_ = mi.rcMonitor.top;
    if (win_y_ + win_h_ > mi.rcMonitor.bottom)
      win_y_ = mi.rcMonitor.bottom - win_h_;
  }
  if (hwnd_) {  // keep the strip above the just-raised scrims
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  // Countdown HUD: recentre on the rect (RenderCountdown, driven by the cd tick,
  // repaints it at the new cd_x_/cd_y_) and keep it above the scrims.
  if (cd_hwnd_) {
    cd_x_ = (r.left + r.right) / 2 - cd_w_ / 2;
    cd_y_ = (r.top + r.bottom) / 2 - cd_h_ / 2;
    SetWindowPos(cd_hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

bool RecordChrome::PollFollow() {
  if (!follow_hwnd_) return false;
  if (!IsWindow(follow_hwnd_)) {
    follow_hwnd_ = nullptr;
    return false;
  }
  RECT r{};
  // The visible window bounds (excludes the invisible resize border), matching
  // what the recorder reported at start (recorder.cpp also uses this).
  if (FAILED(DwmGetWindowAttribute(follow_hwnd_, DWMWA_EXTENDED_FRAME_BOUNDS, &r,
                                   sizeof(r)))) {
    if (!GetWindowRect(follow_hwnd_, &r)) return false;
  }
  // Hysteresis: ignore <=1px jitter so a stationary window costs 0 reframes.
  auto near1 = [](LONG a, LONG b) { return (a > b ? a - b : b - a) <= 1; };
  if (near1(r.left, follow_px_.left) && near1(r.top, follow_px_.top) &&
      near1(r.right, follow_px_.right) && near1(r.bottom, follow_px_.bottom)) {
    return false;
  }
  Reframe(r);
  return true;
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

void RecordChrome::ShowCountdown(int64_t display_id, double x, double y,
                                 double w, double h, int seconds, bool border,
                                 bool scrim, std::function<void()> on_done,
                                 std::function<void()> on_cancel, HWND follow) {
  Hide();  // clean slate (clears frame_up_); the frame is (re)created below
  cd_done_ = std::move(on_done);
  cd_cancel_ = std::move(on_cancel);
  cd_remaining_ = (std::max)(1, seconds);
  follow_hwnd_ = follow;  // track the window during the countdown too (macOS)

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
  // Show the recorded-rect frame (border + scrims) NOW so it is visible during
  // the countdown (macOS parity); it persists into recording (frame_up_).
  CreateFrameOverlays(mon, mi, x, y, w, h, border, scrim);
  cd_w_ = S(kCdPanel);
  cd_h_ = S(kCdPanel);
  int cx, cy;
  if (w > 0 && h > 0) {  // centre on the region; else on the monitor
    cx = mi.rcMonitor.left + S(x + w / 2.0);
    cy = mi.rcMonitor.top + S(y + h / 2.0);
  } else {
    cx = (mi.rcMonitor.left + mi.rcMonitor.right) / 2;
    cy = (mi.rcMonitor.top + mi.rcMonitor.bottom) / 2;
  }
  cd_x_ = cx - cd_w_ / 2;
  cd_y_ = cy - cd_h_ / 2;

  if (!EnsureGraphics()) {
    FinishCountdown(true);  // no graphics -> just proceed to record
    return;
  }
  // The big number format, re-created at the current scale.
  cd_fmt_ = nullptr;
  const float cs = static_cast<float>(72.0 * scale_);  // macOS: 72pt bold number
  if (FAILED(dwrite_->CreateTextFormat(
          L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_BOLD,
          DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, cs, L"",
          cd_fmt_.put()))) {
    FinishCountdown(true);
    return;
  }
  cd_fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
  cd_fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

  EnsureClass();
  cd_hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kClass, L"", WS_POPUP, cd_x_, cd_y_, cd_w_, cd_h_, nullptr, nullptr,
      GetModuleHandleW(nullptr), this);
  if (!cd_hwnd_) {
    FinishCountdown(true);
    return;
  }
  SetWindowDisplayAffinity(cd_hwnd_, WDA_EXCLUDEFROMCAPTURE);
  ShowWindow(cd_hwnd_, SW_SHOWNOACTIVATE);
  RenderCountdown();
  // Tick at ~20Hz (not 1s) so window-follow stays smooth during the countdown;
  // the displayed number decrements on each accumulated 1000ms (see the handler).
  cd_last_dec_ms_ = GetTickCount64();
  SetTimer(cd_hwnd_, kCdTimer, kTickMs, nullptr);
}

void RecordChrome::RenderCountdown() {
  if (!cd_hwnd_ || !dc_ || !cd_fmt_) return;
  const UINT W = static_cast<UINT>(cd_w_), H = static_cast<UINT>(cd_h_);
  if (W == 0 || H == 0) return;
  wchar_t num[8];
  swprintf_s(num, L"%d", cd_remaining_);
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
    // Neutral near-black panel, matching macOS CountdownView srgb(0.07,0.07,0.08)
    // -- NOT the brand slate #0F172A (that read bluish, off vs mac).
    brush->SetColor(D2D1::ColorF(0x121214, 0.92f));
    const float rad = static_cast<float>(26.0 * scale_);  // macOS xRadius 26
    dc_->FillRoundedRectangle(
        D2D1::RoundedRect(
            D2D1::RectF(0, 0, static_cast<float>(W), static_cast<float>(H)), rad,
            rad),
        brush.get());
    brush->SetColor(D2D1::ColorF(0xFFFFFF, 1.0f));  // macOS: solid white number
    dc_->DrawText(num, static_cast<UINT32>(wcslen(num)), cd_fmt_.get(),
                  D2D1::RectF(0, 0, static_cast<float>(W),
                              static_cast<float>(H) * 0.82f),
                  brush.get());
    brush->SetColor(D2D1::ColorF(0xFFFFFF, 0.65f));  // macOS hint: white 0.65
    const std::wstring& hint = labels_.countdown_cancel;
    dc_->DrawText(hint.c_str(), static_cast<UINT32>(hint.size()),
                  label_fmt_.get(),
                  D2D1::RectF(0, static_cast<float>(H) * 0.78f,
                              static_cast<float>(W), static_cast<float>(H)),
                  brush.get());
    winrt::check_hresult(dc_->EndDraw());
    PresentLayered(cd_hwnd_, target.get(), cd_x_, cd_y_, W, H);
    dc_->SetTarget(nullptr);
  } catch (...) {
    if (dc_) dc_->SetTarget(nullptr);
  }
}

void RecordChrome::FinishCountdown(bool done) {
  if (cd_hwnd_) {
    KillTimer(cd_hwnd_, kCdTimer);
    DestroyWindow(cd_hwnd_);
    cd_hwnd_ = nullptr;
  }
  auto done_cb = std::move(cd_done_);
  auto cancel_cb = std::move(cd_cancel_);
  cd_done_ = nullptr;
  cd_cancel_ = nullptr;
  if (done) {
    if (done_cb) done_cb();
  } else if (cancel_cb) {
    cancel_cb();
  }
}

void RecordChrome::ShowBorder(int rx, int ry, int rw, int rh) {
  if (!dc_ || !factory_ || rw <= 0 || rh <= 0) return;
  const int M = (std::max)(8, static_cast<int>(std::lround(20 * scale_)));
  const int bx = rx - M, by = ry - M;
  const UINT W = static_cast<UINT>(rw + 2 * M), H = static_cast<UINT>(rh + 2 * M);

  EnsureOverlayClass();
  border_hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kOverlayClass, L"", WS_POPUP, bx, by, static_cast<int>(W),
      static_cast<int>(H), nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!border_hwnd_) return;
  SetWindowDisplayAffinity(border_hwnd_, WDA_EXCLUDEFROMCAPTURE);
  ShowWindow(border_hwnd_, SW_SHOWNOACTIVATE);

  auto S = [this](double v) { return static_cast<float>(v * scale_); };
  const float fM = static_cast<float>(M);
  const float Lx = fM, Ty = fM, Rx = fM + rw, By = fM + rh;
  const float rad = S(3);
  const D2D1_ROUNDED_RECT rr =
      D2D1::RoundedRect(D2D1::RectF(Lx, Ty, Rx, By), rad, rad);
  const auto pf = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                    D2D1_ALPHA_MODE_PREMULTIPLIED);
  const auto tp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, pf);
  try {
    // Pass A: the glow source -- the rounded edge at the shadow alpha (0.18).
    winrt::com_ptr<ID2D1Bitmap1> glow_src;
    winrt::check_hresult(
        dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0, tp, glow_src.put()));
    winrt::com_ptr<ID2D1SolidColorBrush> b;
    dc_->SetTarget(glow_src.get());
    dc_->BeginDraw();
    dc_->Clear(D2D1::ColorF(0, 0, 0, 0));
    dc_->CreateSolidColorBrush(D2D1::ColorF(0xFF453A, 0.18f), b.put());
    dc_->DrawRoundedRectangle(rr, b.get(), S(1));
    winrt::check_hresult(dc_->EndDraw());

    // Pass B: blurred glow + the sharp 1px edge (0.55) + viewfinder brackets.
    winrt::com_ptr<ID2D1Bitmap1> target;
    winrt::check_hresult(
        dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0, tp, target.put()));
    dc_->SetTarget(target.get());
    dc_->BeginDraw();
    dc_->Clear(D2D1::ColorF(0, 0, 0, 0));
    winrt::com_ptr<ID2D1Effect> blur;
    if (SUCCEEDED(dc_->CreateEffect(kCLSID_GaussianBlur, blur.put()))) {
      blur->SetInput(0, glow_src.get());
      blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION,
                     static_cast<float>(6.0 * scale_));
      dc_->DrawImage(blur.get());
    }
    winrt::com_ptr<ID2D1SolidColorBrush> edge;
    dc_->CreateSolidColorBrush(D2D1::ColorF(0xFF453A, 0.55f), edge.put());
    dc_->DrawRoundedRectangle(rr, edge.get(), S(1));

    // Viewfinder corner brackets, faithful to macOS RecordingFrameView: 22pt
    // arms, 3pt stroke, BUTT caps, and a 4.5pt rounded elbow drawn as an explicit
    // arc (the earlier round line-join only rounded by stroke/2 = 1.5pt, which
    // read as "slightly off").
    const float arm = S(22);
    const float r = S(4.5);
    D2D1_STROKE_STYLE_PROPERTIES sp{};
    sp.startCap = D2D1_CAP_STYLE_FLAT;
    sp.endCap = D2D1_CAP_STYLE_FLAT;
    sp.dashCap = D2D1_CAP_STYLE_FLAT;
    sp.lineJoin = D2D1_LINE_JOIN_ROUND;
    sp.miterLimit = 10.0f;
    sp.dashStyle = D2D1_DASH_STYLE_SOLID;
    winrt::com_ptr<ID2D1StrokeStyle> ss;
    factory_->CreateStrokeStyle(sp, nullptr, 0, ss.put());
    winrt::com_ptr<ID2D1PathGeometry> geom;
    winrt::com_ptr<ID2D1SolidColorBrush> rb;
    dc_->CreateSolidColorBrush(D2D1::ColorF(0xFF453A, 1.0f), rb.put());
    if (SUCCEEDED(factory_->CreatePathGeometry(geom.put()))) {
      winrt::com_ptr<ID2D1GeometrySink> sink;
      if (SUCCEEDED(geom->Open(sink.put()))) {
        // arm0 -line-> a0 -arc(r)-> a1 -line-> arm1; the arc is tangent to both
        // arms (radius perpendicular to each), so the elbow is a smooth round.
        auto bracket = [&](D2D1_POINT_2F arm0, D2D1_POINT_2F a0,
                           D2D1_POINT_2F a1, D2D1_POINT_2F arm1,
                           D2D1_SWEEP_DIRECTION sweep) {
          sink->BeginFigure(arm0, D2D1_FIGURE_BEGIN_HOLLOW);
          sink->AddLine(a0);
          sink->AddArc(D2D1::ArcSegment(a1, D2D1::SizeF(r, r), 0.0f, sweep,
                                        D2D1_ARC_SIZE_SMALL));
          sink->AddLine(arm1);
          sink->EndFigure(D2D1_FIGURE_END_OPEN);
        };
        bracket(D2D1::Point2F(Lx + arm, Ty), D2D1::Point2F(Lx + r, Ty),
                D2D1::Point2F(Lx, Ty + r), D2D1::Point2F(Lx, Ty + arm),
                D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE);  // top-left
        bracket(D2D1::Point2F(Rx - arm, Ty), D2D1::Point2F(Rx - r, Ty),
                D2D1::Point2F(Rx, Ty + r), D2D1::Point2F(Rx, Ty + arm),
                D2D1_SWEEP_DIRECTION_CLOCKWISE);  // top-right
        bracket(D2D1::Point2F(Rx, By - arm), D2D1::Point2F(Rx, By - r),
                D2D1::Point2F(Rx - r, By), D2D1::Point2F(Rx - arm, By),
                D2D1_SWEEP_DIRECTION_CLOCKWISE);  // bottom-right
        bracket(D2D1::Point2F(Lx, By - arm), D2D1::Point2F(Lx, By - r),
                D2D1::Point2F(Lx + r, By), D2D1::Point2F(Lx + arm, By),
                D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE);  // bottom-left
        sink->Close();
        dc_->DrawGeometry(geom.get(), rb.get(), S(3), ss.get());
      }
    }
    winrt::check_hresult(dc_->EndDraw());
    PresentLayered(border_hwnd_, target.get(), bx, by, W, H);
    dc_->SetTarget(nullptr);
  } catch (...) {
    if (dc_) dc_->SetTarget(nullptr);
  }
}

void RecordChrome::TearStrip() {
  // Tear ONLY the strip + countdown HUD windows; leaves the frame overlays
  // (border + scrims) intact so the countdown -> recording transition is seamless.
  if (cd_hwnd_) {
    KillTimer(cd_hwnd_, kCdTimer);
    DestroyWindow(cd_hwnd_);
    cd_hwnd_ = nullptr;
    cd_done_ = nullptr;
    cd_cancel_ = nullptr;
  }
  if (hwnd_) {
    KillTimer(hwnd_, kTickTimer);
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

void RecordChrome::Hide() {
  TearStrip();
  if (border_hwnd_) {
    DestroyWindow(border_hwnd_);
    border_hwnd_ = nullptr;
  }
  border_rw_ = 0;
  border_rh_ = 0;
  for (HWND s : scrim_hwnds_) {
    if (s) DestroyWindow(s);
  }
  scrim_hwnds_.clear();
  for (HWND& s : inrect_scrim_) {
    if (s) DestroyWindow(s);
    s = nullptr;
  }
  follow_hwnd_ = nullptr;
  strip_detached_ = false;
  frame_up_ = false;
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
  // The countdown HUD shares this handler (routed by the same `this`); a tick
  // decrements it, a click cancels it.
  if (hwnd == cd_hwnd_) {
    if (msg == WM_TIMER && wp == kCdTimer) {
      const bool reframed = PollFollow();  // follow the window during countdown
      const ULONGLONG now = GetTickCount64();
      bool dec = false;
      if (now - cd_last_dec_ms_ >= 1000) {
        cd_last_dec_ms_ += 1000;
        dec = true;
        if (--cd_remaining_ <= 0) {
          FinishCountdown(true);
          return 0;
        }
      }
      if (dec || reframed) RenderCountdown();
      return 0;
    }
    if (msg == WM_LBUTTONUP) {
      FinishCountdown(false);
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  switch (msg) {
    case WM_TIMER:
      if (wp == kTickTimer) {
        const bool reframed = PollFollow();  // window-follow (window mode)
        if (abort_armed_ && GetTickCount64() - abort_arm_ms_ > 3000) {
          abort_armed_ = false;  // auto-disarm after 3s
          Render();
        } else if (!paused_ || reframed) {
          // Breathing render (~20 fps) + the 2 Hz size/timer refresh inside it.
          // Normally skipped while paused (static dim dot, frozen timer) to stay
          // idle -- but a follow-reframe while paused still needs one repaint to
          // move the strip to the window's new position.
          Render();
        }
        return 0;
      }
      break;
    case WM_LBUTTONDOWN: {
      POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      if (HitTest(p) == 0) {  // press on the bar body -> drag the strip
        POINT c{};
        GetCursorPos(&c);
        drag_off_ = {c.x - win_x_, c.y - win_y_};
        dragging_ = true;
        strip_detached_ = true;  // a manual drag detaches the strip from follow
        SetCapture(hwnd);
      }
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (dragging_) {
        POINT c{};
        GetCursorPos(&c);
        win_x_ = c.x - drag_off_.x;
        win_y_ = c.y - drag_off_.y;
        Render();  // UpdateLayeredWindow repositions to the new origin
        return 0;
      }
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
      if (dragging_) {
        dragging_ = false;
        ReleaseCapture();
        return 0;
      }
      POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      const int h = HitTest(p);
      if (h == 3) {  // Abort = two-step: arm, then confirm within 3s
        if (!abort_armed_) {
          abort_armed_ = true;
          abort_arm_ms_ = GetTickCount64();
          Render();
        } else {
          abort_armed_ = false;
          if (cb_.on_abort) cb_.on_abort();
        }
        return 0;
      }
      if (abort_armed_) {  // any other click disarms a pending Abort
        abort_armed_ = false;
        Render();
      }
      if (h == 1) {
        if (cb_.on_stop) cb_.on_stop();
      } else if (h == 2) {
        if (cb_.on_pause_toggle) cb_.on_pause_toggle();
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
  wchar_t timer[24];
  if (max_duration_sec_ > 0) {  // "elapsed / total" under auto-stop (macOS parity)
    const long long tot = max_duration_sec_;
    swprintf_s(timer, L"%02lld:%02lld / %02lld:%02lld", secs / 60, secs % 60,
               tot / 60, tot % 60);
  } else {
    swprintf_s(timer, L"%02lld:%02lld", secs / 60, secs % 60);
  }

  // Theme palette (macOS strip follows the system appearance; the recording red
  // is constant in both). fg1 = timer, fg3 = size readout.
  const D2D1_COLOR_F barColor = light_ ? D2D1::ColorF(0xF7F8FB, 0.96f)
                                       : D2D1::ColorF(0x1A1E28, 0.96f);
  const D2D1_COLOR_F fg1 = light_ ? D2D1::ColorF(0x14223B, 1.0f)
                                  : D2D1::ColorF(0xFFFFFF, 0.96f);
  const D2D1_COLOR_F fg3 = light_ ? D2D1::ColorF(0x64748B, 1.0f)
                                  : D2D1::ColorF(0xFFFFFF, 0.46f);
  const D2D1_COLOR_F divColor = light_ ? D2D1::ColorF(0x0F172A, 0.10f)
                                       : D2D1::ColorF(0xFFFFFF, 0.14f);

  // Refresh the size/frames readout at most every kDetailMs (the on-disk poll /
  // frame-count read), independent of the ~20 fps breathing render.
  if (last_detail_.empty() || (now - last_detail_ms_) >= kDetailMs) {
    if (gif_) {
      const int frames = frame_count_ ? frame_count_() : 0;
      last_detail_ = std::to_wstring(frames) + L" " + labels_.frames;
    } else {
      ULONGLONG bytes = 0;
      WIN32_FILE_ATTRIBUTE_DATA fad{};
      if (!out_path_w_.empty() &&
          GetFileAttributesExW(out_path_w_.c_str(), GetFileExInfoStandard,
                               &fad)) {
        bytes = (static_cast<ULONGLONG>(fad.nFileSizeHigh) << 32) |
                fad.nFileSizeLow;
      }
      wchar_t mb[24];
      swprintf_s(mb, L"%.1f MB", static_cast<double>(bytes) / 1048576.0);
      last_detail_ = mb;
    }
    last_detail_ms_ = now;
  }

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

    // Near-solid themed bar.
    const float rad = S(11);
    fill(D2D1::RectF(0, 0, static_cast<float>(W), static_cast<float>(H)), rad,
         barColor);

    // Auto-stop progress rail along the bottom edge.
    if (max_duration_sec_ > 0) {
      double frac = static_cast<double>(secs) / max_duration_sec_;
      if (frac < 0) frac = 0;
      if (frac > 1) frac = 1;
      const float ph = S(3);
      const float y0 = static_cast<float>(H) - ph;
      brush->SetColor(D2D1::ColorF(0xFF453A, 0.16f));
      dc_->FillRectangle(
          D2D1::RectF(rad, y0, static_cast<float>(W) - rad, static_cast<float>(H)),
          brush.get());
      brush->SetColor(D2D1::ColorF(0xFF453A, 0.9f));
      const float x1 =
          rad + static_cast<float>((static_cast<double>(W) - 2 * rad) * frac);
      dc_->FillRectangle(D2D1::RectF(rad, y0, x1, static_cast<float>(H)),
                         brush.get());
    }

    // Breathing recording dot (macOS RecordingDotView): a calm glow swelling
    // over ~1.7 s; steady + dim while paused (the breath render is skipped then).
    const float cy = H / 2.0f;
    const float dotx = S(kPad) + S(5);
    double e = 0.0;
    if (!paused_) {
      const double t = static_cast<double>((now - start_ms_) % 1700) / 1700.0;
      const double tri = t < 0.5 ? t * 2.0 : 2.0 - t * 2.0;  // 0..1..0
      e = tri * tri * (3.0 - 2.0 * tri);                     // smoothstep ease
    }
    if (e > 0.01) {  // soft radial glow halo
      const float gr = S(5) + S(1.5) + static_cast<float>(e) * S(4.5);
      D2D1_GRADIENT_STOP gg[2] = {
          {0.0f, D2D1::ColorF(0xFF453A, static_cast<float>(e) * 0.55f)},
          {1.0f, D2D1::ColorF(0xFF453A, 0.0f)}};
      com_ptr<ID2D1GradientStopCollection> gc;
      if (SUCCEEDED(dc_->CreateGradientStopCollection(gg, 2, gc.put()))) {
        com_ptr<ID2D1RadialGradientBrush> rb;
        if (SUCCEEDED(dc_->CreateRadialGradientBrush(
                D2D1::RadialGradientBrushProperties(D2D1::Point2F(dotx, cy),
                                                    D2D1::Point2F(0, 0), gr, gr),
                gc.get(), rb.put()))) {
          dc_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(dotx, cy), gr, gr),
                           rb.get());
        }
      }
    }
    brush->SetColor(D2D1::ColorF(0xFF453A, paused_ ? 0.45f : 1.0f));
    dc_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(dotx, cy), S(5), S(5)),
                     brush.get());

    // Timer text (fg1).
    brush->SetColor(fg1);
    dc_->DrawText(timer, static_cast<UINT32>(wcslen(timer)), timer_fmt_.get(),
                  D2D1::RectF(static_cast<float>(timer_x_), 0,
                              static_cast<float>(timer_x_ + timer_w_),
                              static_cast<float>(H)),
                  brush.get());

    // File-size (mp4) / frame-count (GIF) readout (fg3), right-aligned.
    brush->SetColor(fg3);
    dc_->DrawText(last_detail_.c_str(),
                  static_cast<UINT32>(last_detail_.size()), size_fmt_.get(),
                  D2D1::RectF(static_cast<float>(size_x_), 0,
                              static_cast<float>(size_x_ + size_w_),
                              static_cast<float>(H)),
                  brush.get());

    // Hairline divider between the readouts and the buttons (macOS sep).
    brush->SetColor(divColor);
    const float dvx = static_cast<float>(div_x_);
    dc_->FillRectangle(
        D2D1::RectF(dvx, cy - S(11), dvx + (std::max)(1.0f, S(1)), cy + S(11)),
        brush.get());

    // Ghost buttons (Pause/Resume, Abort): borderless; hover/emphasis paint a
    // faint wash; the armed Abort shows a red "Confirm?" label; the paused
    // Resume reads as the primary action (full-strength fg1 + faint always-on
    // wash), neutral so it never collides with the red Finish.
    auto draw_ghost = [&](const RECT& rc, const std::wstring& label, bool hover,
                          bool armed, bool emphasized) {
      const D2D1_RECT_F r = D2D1::RectF(
          static_cast<float>(rc.left), static_cast<float>(rc.top),
          static_cast<float>(rc.right), static_cast<float>(rc.bottom));
      const float br = S(9);
      const float washA = armed ? 0.0f
                          : hover ? (emphasized ? 0.07f : 0.05f)
                                  : (emphasized ? 0.05f : 0.0f);
      if (washA > 0) {
        brush->SetColor(light_ ? D2D1::ColorF(0x0F172A, washA)
                               : D2D1::ColorF(0xFFFFFF, washA));
        dc_->FillRoundedRectangle(D2D1::RoundedRect(r, br, br), brush.get());
      }
      D2D1_COLOR_F fg;
      if (armed) {
        fg = D2D1::ColorF(0xFF453A, 1.0f);  // danger confirm
      } else if (emphasized) {
        fg = fg1;
      } else if (light_) {
        fg = hover ? D2D1::ColorF(0x475569, 1.0f) : D2D1::ColorF(0x64748B, 1.0f);
      } else {
        fg = D2D1::ColorF(0xFFFFFF, hover ? 0.66f : 0.46f);
      }
      brush->SetColor(fg);
      dc_->DrawText(label.c_str(), static_cast<UINT32>(label.size()),
                    label_fmt_.get(), r, brush.get());
    };

    // Finish (accent): a 135deg recording-red gradient + a stop-square glyph
    // before the label, the pair centered as a group; a faint white hover wash.
    auto draw_finish = [&](const RECT& rc, bool hover) {
      const D2D1_RECT_F r = D2D1::RectF(
          static_cast<float>(rc.left), static_cast<float>(rc.top),
          static_cast<float>(rc.right), static_cast<float>(rc.bottom));
      const float br = S(9);
      D2D1_GRADIENT_STOP gs[2] = {{0.0f, D2D1::ColorF(0xFF453A, 1.0f)},
                                  {1.0f, D2D1::ColorF(0xFF6A60, 1.0f)}};
      com_ptr<ID2D1GradientStopCollection> coll;
      if (SUCCEEDED(dc_->CreateGradientStopCollection(gs, 2, coll.put()))) {
        com_ptr<ID2D1LinearGradientBrush> lg;
        if (SUCCEEDED(dc_->CreateLinearGradientBrush(
                D2D1::LinearGradientBrushProperties(
                    D2D1::Point2F(r.left, r.top),
                    D2D1::Point2F(r.right, r.bottom)),
                coll.get(), lg.put()))) {
          com_ptr<ID2D1RoundedRectangleGeometry> geo;
          if (SUCCEEDED(factory_->CreateRoundedRectangleGeometry(
                  D2D1::RoundedRect(r, br, br), geo.put()))) {
            dc_->FillGeometry(geo.get(), lg.get());
          }
        }
      }
      if (hover) {
        brush->SetColor(D2D1::ColorF(0xFFFFFF, 0.12f));
        dc_->FillRoundedRectangle(D2D1::RoundedRect(r, br, br), brush.get());
      }
      // Glyph (white rounded square) + label, centered as a group.
      const float lw = MeasureWidth(label_fmt_.get(), labels_.finish.c_str());
      const float gbox = S(12), ggap = S(7), sq = S(7);
      const float contentW = gbox + ggap + lw;
      const float sx = r.left + ((r.right - r.left) - contentW) / 2.0f;
      const float sqx = sx + (gbox - sq) / 2.0f;
      brush->SetColor(D2D1::ColorF(0xFFFFFF, 1.0f));
      dc_->FillRoundedRectangle(
          D2D1::RoundedRect(D2D1::RectF(sqx, cy - sq / 2, sqx + sq, cy + sq / 2),
                            S(2), S(2)),
          brush.get());
      dc_->DrawText(labels_.finish.c_str(),
                    static_cast<UINT32>(labels_.finish.size()),
                    btn_lead_fmt_.get(),
                    D2D1::RectF(sx + gbox + ggap, r.top, r.right, r.bottom),
                    brush.get());
    };

    draw_ghost(pause_rc_, paused_ ? labels_.resume : labels_.pause, hover_ == 2,
               false, paused_);
    draw_ghost(abort_rc_, abort_armed_ ? labels_.confirm : labels_.abort,
               hover_ == 3, abort_armed_, false);
    draw_finish(stop_rc_, hover_ == 1);

    winrt::check_hresult(dc_->EndDraw());
    PresentLayered(hwnd_, target.get(), win_x_, win_y_, W, H);
    dc_->SetTarget(nullptr);
  } catch (...) {
    if (dc_) dc_->SetTarget(nullptr);
  }
}

void RecordChrome::PresentLayered(HWND hwnd, ID2D1Bitmap1* target, int x, int y,
                                  UINT W, UINT H) {
  const auto pf = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                    D2D1_ALPHA_MODE_PREMULTIPLIED);
  const auto rp = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, pf);
  com_ptr<ID2D1Bitmap1> readback;
  if (FAILED(dc_->CreateBitmap(D2D1::SizeU(W, H), nullptr, 0, rp,
                               readback.put()))) {
    return;
  }
  D2D1_POINT_2U dst = D2D1::Point2U(0, 0);
  D2D1_RECT_U src = D2D1::RectU(0, 0, W, H);
  if (FAILED(readback->CopyFromBitmap(&dst, target, &src))) return;
  D2D1_MAPPED_RECT mapped{};
  if (FAILED(readback->Map(D2D1_MAP_OPTIONS_READ, &mapped))) return;

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
    POINT dst_pt = {x, y};
    BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd, screen, &dst_pt, &size, mem, &src_pt, 0, &bf,
                        ULW_ALPHA);
    SelectObject(mem, old);
    DeleteDC(mem);
  }
  if (dib) DeleteObject(dib);
  ReleaseDC(nullptr, screen);
  readback->Unmap();
}
