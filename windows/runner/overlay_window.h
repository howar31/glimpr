#ifndef RUNNER_OVERLAY_WINDOW_H_
#define RUNNER_OVERLAY_WINDOW_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

// A borderless, top-most, OPAQUE window covering exactly one monitor, hosting
// its own Flutter engine + view (engine-per-surface). The Windows analogue of
// the macOS OverlayWindow + its warmed FlutterViewController, MINUS the
// transparency: the architecture checkpoint fixes the Windows overlay as opaque
// + rectangular (no per-pixel alpha). Created hidden; revealed only after its
// Dart paints the frozen frame (capture-then-show). One instance per display.
class OverlayWindow {
 public:
  OverlayWindow();
  ~OverlayWindow();

  OverlayWindow(const OverlayWindow&) = delete;
  OverlayWindow& operator=(const OverlayWindow&) = delete;

  // Build the window + its Flutter view controller (a fresh runtime engine) at
  // the monitor's PHYSICAL bounds [monitor_px]. Starts HIDDEN. Returns false on
  // any failure (the caller drops the unit).
  bool Create(const flutter::DartProject& project, const RECT& monitor_px);

  // Reveal over [monitor_px] (re-positions first, in case the display moved).
  // [activate] = take foreground (the cursor display); else show without
  // stealing activation (SW_SHOWNA) so a non-cursor display does not grab keys.
  void Show(const RECT& monitor_px, bool activate);

  // Hide but keep the engine warm + resident (SW_HIDE; never destroyed between
  // captures, so the next capture re-reveals instantly).
  void Hide();

  // Bring this window to the foreground (the cursor poll re-keys the active
  // display). Best-effort against Windows' SetForegroundWindow restrictions.
  void SetForeground();

  bool visible() const { return visible_; }
  HWND hwnd() const { return hwnd_; }
  flutter::FlutterViewController* controller() const { return controller_.get(); }
  flutter::BinaryMessenger* messenger() const;

  // The window-class WndProc (public so the class registrar can reference it).
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

 private:
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept;

  HWND hwnd_ = nullptr;
  HWND child_ = nullptr;  // the Flutter view's native window
  bool visible_ = false;
  std::unique_ptr<flutter::FlutterViewController> controller_;
};

#endif  // RUNNER_OVERLAY_WINDOW_H_
