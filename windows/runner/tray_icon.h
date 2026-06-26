#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>

#include "hotkey_host.h"

#define WM_GLIMPR_TRAY (WM_APP + 1)

// The system-tray (Shell_NotifyIcon) shell: a brand-icon tray entry + a context
// menu mirroring the macOS NSStatusItem menu. Live items fire through the SAME
// Dart dispatcher as the hotkeys (HotkeyHost::FireAction); not-yet-built items
// are greyed; Settings / About / Quit are native callbacks. Left- or right-click
// pops the menu; double-click reveals Settings. In-runner; mirrors
// StatusItemController.swift.
class TrayIcon {
 public:
  struct Callbacks {
    std::function<void()> on_reveal_settings;
    std::function<void()> on_about;
    std::function<void()> on_quit;
  };

  TrayIcon(HWND owner, HINSTANCE instance, HotkeyHost* hotkeys,
           Callbacks callbacks);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Single-click timer id (set on owner_; routed back via WM_TIMER). A left
  // single-click pops the menu only after one double-click interval, so a
  // double-click (reveal Settings) wins instead of also opening the menu.
  static constexpr UINT_PTR kClickTimerId = 0xA001;

  // Routed from FlutterWindow::MessageHandler (uCallbackMessage WM_GLIMPR_TRAY).
  void OnTrayMessage(WPARAM wparam, LPARAM lparam);
  // Routed from FlutterWindow::MessageHandler (WM_TIMER, wparam == kClickTimerId):
  // the pending left single-click resolved (no double-click arrived) -> pop menu.
  void OnSingleClickTimer();
  void Remove();

 private:
  void ShowMenu();
  void OnCommand(UINT command_id);

  HWND owner_ = nullptr;
  HotkeyHost* hotkeys_ = nullptr;  // not owned
  Callbacks cb_;
  bool added_ = false;
  bool suppress_next_up_ = false;  // ignore the trailing up of a double-click
};

#endif  // RUNNER_TRAY_ICON_H_
