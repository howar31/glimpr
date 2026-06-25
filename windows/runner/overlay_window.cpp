#include "overlay_window.h"

#include <flutter/generated_plugin_registrant.h>

#include <optional>

namespace {

constexpr const wchar_t kOverlayClassName[] = L"GLIMPR_OVERLAY_WINDOW";
bool g_class_registered = false;

const wchar_t* EnsureWindowClass() {
  if (!g_class_registered) {
    WNDCLASSW wc{};
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = OverlayWindow::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    // Opaque black backing so any frame painted before Flutter's first raster is
    // black, never a white flash (we only Show after overlayReady anyway).
    wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = kOverlayClassName;
    RegisterClassW(&wc);
    g_class_registered = true;
  }
  return kOverlayClassName;
}

}  // namespace

OverlayWindow::OverlayWindow() = default;

OverlayWindow::~OverlayWindow() {
  if (controller_) {
    controller_ = nullptr;  // tears down the engine + view
  }
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

bool OverlayWindow::Create(const flutter::DartProject& project,
                           const RECT& monitor_px) {
  const wchar_t* cls = EnsureWindowClass();
  const int w = monitor_px.right - monitor_px.left;
  const int h = monitor_px.bottom - monitor_px.top;
  if (w <= 0 || h <= 0) return false;

  // Borderless (WS_POPUP), top-most, no taskbar button (WS_EX_TOOLWINDOW),
  // covering the whole monitor. Opaque (no WS_EX_LAYERED). Created hidden.
  hwnd_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW, cls, L"", WS_POPUP, monitor_px.left,
      monitor_px.top, w, h, nullptr, nullptr, GetModuleHandle(nullptr), this);
  if (!hwnd_) return false;

  controller_ = std::make_unique<flutter::FlutterViewController>(w, h, project);
  if (!controller_->engine() || !controller_->view()) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
    controller_ = nullptr;
    return false;
  }
  RegisterPlugins(controller_->engine());

  child_ = controller_->view()->GetNativeWindow();
  SetParent(child_, hwnd_);
  MoveWindow(child_, 0, 0, w, h, TRUE);
  // Nudge the engine so it produces a first frame even though the host window is
  // still hidden; Dart signals overlayReady once it has painted the frozen frame.
  controller_->ForceRedraw();
  return true;
}

void OverlayWindow::Show(const RECT& monitor_px, bool activate) {
  if (!hwnd_) return;
  const int w = monitor_px.right - monitor_px.left;
  const int h = monitor_px.bottom - monitor_px.top;
  UINT flags = SWP_SHOWWINDOW;
  if (!activate) flags |= SWP_NOACTIVATE;
  SetWindowPos(hwnd_, HWND_TOPMOST, monitor_px.left, monitor_px.top, w, h, flags);
  if (child_) MoveWindow(child_, 0, 0, w, h, TRUE);
  visible_ = true;
  if (activate) SetForeground();
}

void OverlayWindow::Hide() {
  if (!hwnd_) return;
  ShowWindow(hwnd_, SW_HIDE);
  visible_ = false;
}

void OverlayWindow::SetForeground() {
  if (!hwnd_) return;
  // Windows restricts SetForegroundWindow to the foreground process; attach to
  // the current foreground thread's input queue so the borderless overlay can
  // legitimately take focus + keyboard.
  HWND fg = GetForegroundWindow();
  DWORD fg_thread = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
  DWORD self_thread = GetCurrentThreadId();
  if (fg_thread && fg_thread != self_thread) {
    AttachThreadInput(self_thread, fg_thread, TRUE);
  }
  SetForegroundWindow(hwnd_);
  SetFocus(hwnd_);
  if (child_) SetFocus(child_);
  if (fg_thread && fg_thread != self_thread) {
    AttachThreadInput(self_thread, fg_thread, FALSE);
  }
}

flutter::BinaryMessenger* OverlayWindow::messenger() const {
  return controller_ ? controller_->engine()->messenger() : nullptr;
}

// static
LRESULT CALLBACK OverlayWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    auto* self = static_cast<OverlayWindow*>(cs->lpCreateParams);
    self->hwnd_ = hwnd;
  } else if (auto* self = reinterpret_cast<OverlayWindow*>(
                 GetWindowLongPtr(hwnd, GWLP_USERDATA))) {
    return self->MessageHandler(hwnd, message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT OverlayWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept {
  if (controller_) {
    std::optional<LRESULT> r =
        controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (r) return *r;
  }
  switch (message) {
    case WM_SIZE: {
      RECT rc{};
      GetClientRect(hwnd, &rc);
      if (child_) {
        MoveWindow(child_, 0, 0, rc.right - rc.left, rc.bottom - rc.top, TRUE);
      }
      return 0;
    }
    case WM_ACTIVATE:
      if (child_) SetFocus(child_);
      return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
