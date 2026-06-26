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

  // Routed from FlutterWindow::MessageHandler (uCallbackMessage WM_GLIMPR_TRAY).
  // Right-click pops the menu; double-click opens Settings; left single-click
  // does nothing (owner choice) -> no single/double-click conflict, no timer.
  void OnTrayMessage(WPARAM wparam, LPARAM lparam);
  // Routed from FlutterWindow::MessageHandler (WM_SETTINGCHANGE / ImmersiveColorSet):
  // re-tint the tray mark when the taskbar flips between light and dark.
  void OnThemeChanged();
  void Remove();

 private:
  void ShowMenu();
  void OnCommand(UINT command_id);
  // The viewfinder mark tinted for the CURRENT taskbar theme (white mark on a
  // dark taskbar, dark mark on a light one), at the small-icon size. Caller owns
  // the returned HICON (DestroyIcon).
  HICON LoadThemeIcon() const;

  HWND owner_ = nullptr;
  HINSTANCE instance_ = nullptr;
  HotkeyHost* hotkeys_ = nullptr;  // not owned
  Callbacks cb_;
  bool added_ = false;
  HICON icon_ = nullptr;  // current tray HICON (DestroyIcon on replace / remove)
};

#endif  // RUNNER_TRAY_ICON_H_
