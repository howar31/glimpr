#include "overlay_window.h"

#include <dwmapi.h>
#include <flutter/generated_plugin_registrant.h>

#include <optional>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011  // Win10 2004+; excludes from WGC capture
#endif
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif

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
    // NO background brush (like the standard Flutter window): a brush would make
    // SW_SHOW erase the client area (to black) for a frame before DWM composites
    // the swapchain -> a visible flash. With no brush the window reveals straight
    // to the already-rendered frozen frame (we Show only after the next-frame
    // callback, so the swapchain is current).
    wc.hbrBackground = nullptr;
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
  // Permanent DWM "glass sheet": DWM composites the Flutter surface's
  // premultiplied alpha against the desktop, so a frozen screenshot's alpha-255
  // pixels read opaque while the live record-select picker's transparent base
  // lets the real desktop show through -- ONE window composites every layer
  // (mirrors the macOS always-transparent NSWindow).
  const MARGINS glass{-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(hwnd_, &glass);
  return true;
}

void OverlayWindow::Show(const RECT& monitor_px, bool activate) {
  if (!hwnd_) return;
  const int w = monitor_px.right - monitor_px.left;
  const int h = monitor_px.bottom - monitor_px.top;
  // Match the child to the monitor BEFORE revealing the window (a post-show
  // child resize would repaint = flash). The child was already sized at Create;
  // resize only on a real change (e.g. a re-homed display of a different size).
  if (child_) {
    RECT cc{};
    GetClientRect(hwnd_, &cc);
    if (cc.right != w || cc.bottom != h) MoveWindow(child_, 0, 0, w, h, FALSE);
  }
  UINT flags = SWP_SHOWWINDOW;
  if (!activate) flags |= SWP_NOACTIVATE;
  SetWindowPos(hwnd_, HWND_TOPMOST, monitor_px.left, monitor_px.top, w, h, flags);
  visible_ = true;
  if (activate) SetForeground();
}

void OverlayWindow::Hide() {
  if (!hwnd_) return;
  ShowWindow(hwnd_, SW_HIDE);
  visible_ = false;
}

void OverlayWindow::SetCaptureExcluded(bool excluded) {
  if (!hwnd_) return;
  // Exclude only while a live record-select loupe feed runs, so the loupe's WGC
  // feed sees the true desktop, not the dim veil. Re-include otherwise so a
  // recording over a screenshot session captures the overlay as content. (The
  // DWM glass is permanent -- applied in Create -- so this never changes opacity.)
  SetWindowDisplayAffinity(hwnd_, excluded ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
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
