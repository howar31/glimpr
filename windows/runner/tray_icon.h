#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <map>
#include <string>
#include <vector>

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
    // Open Recent submenu: reveal the editor on the chosen path; clear the list.
    std::function<void(const std::string&)> on_open_recent;
    std::function<void()> on_clear_recent;
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

  // The "Open Recent" submenu source: the editor engine pushes its recent-images
  // list here (basename shown; full path kept for the callback). Newest first.
  void SetRecentImages(std::vector<std::string> paths);

  // Localized menu labels (UTF-8), pushed by the control engine's Dart (the
  // runner C++ is ASCII-only, so it cannot hold the zh strings). Keyed by a
  // stable id; ShowMenu falls back to the English default when a key is absent.
  void SetLabels(std::map<std::string, std::string> labels);

  // Reflect the recording state on the tray mark (mirrors macOS
  // StatusItemController.setRecording): the mark breathes recording-red (~1.7s)
  // while [active]; on stop it eases back to the idle theme tint when [graceful]
  // (a normal finish) or snaps back immediately otherwise (abort / failure).
  // Reduced motion (SPI_GETCLIENTAREAANIMATION off) holds solid red, no animation.
  void SetRecordingState(bool active, bool graceful);

 private:
  void ShowMenu();
  void OnCommand(UINT command_id);
  void OnRecordTick();                      // one breath/ease-out frame
  HICON MakeTintedIcon(double mix) const;   // the base mark blended toward red
  void ApplyIcon(HICON icon);               // NIM_MODIFY + take ownership of icon_
  static void CALLBACK RecordTimerProc(HWND, UINT, UINT_PTR, DWORD);
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
  std::vector<std::string> recent_;  // Open Recent submenu (full paths, newest first)
  std::map<std::string, std::string> labels_;  // localized menu labels (UTF-8)

  // Recording-state breath animation.
  UINT_PTR record_timer_ = 0;
  bool recording_ = false;
  bool ease_out_ = false;
  unsigned long long record_start_ms_ = 0;
  unsigned long long ease_start_ms_ = 0;
  static TrayIcon* s_record_instance_;  // routes the record-tick timer callback
};

#endif  // RUNNER_TRAY_ICON_H_
