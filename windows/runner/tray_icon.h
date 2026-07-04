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

  // Reflect a "processing" state on the tray mark (mirrors macOS
  // StatusItemController.setProcessing): the brand mark fills with the LOGO
  // gradient (cyan #22D3EE -> blue #3B82F6 -> violet #A78BFA along ~-45deg) and
  // PULSES (~0.5s, punchier + faster than the recording-red breath, so the two
  // never read alike) while a capture export / recording finalize / editor
  // export is in flight. [active]=false requests a stop that lands at the next
  // pulse low after >= 1 full cycle, so even an instant operation shows one
  // pulse. Reduced motion holds a static gradient fill. Ignored while recording
  // (the red breath owns the mark; the finalize flow snaps red off first).
  // [tip_utf8] (localized, e.g. "Processing screenshot...") becomes the tray
  // tooltip while the pulse runs, so hovering says WHAT is processing; the
  // tooltip reverts to "Glimpr" when the pulse ends. Empty = keep the tooltip.
  // [unbounded] exempts the pulse from the 10s safety ceiling: the recording
  // finalize legitimately runs longer (a long GIF encodes for tens of seconds)
  // and its native start/stop pair can never miss.
  void SetProcessing(bool active, const std::string& tip_utf8 = std::string(),
                     bool unbounded = false);

  // A pushed localized label by id (see SetLabels), or [fallback] when absent.
  // Used for tips whose trigger is native-initiated (recording finalize), where
  // no channel argument can carry the label.
  std::string Label(const std::string& id, const std::string& fallback) const;

 private:
  void ShowMenu();
  void OnCommand(UINT command_id);
  void OnRecordTick();                      // one breath/ease-out frame
  void OnProcTick();                        // one processing-pulse frame
  HICON MakeTintedIcon(double mix) const;   // the base mark blended toward red
  HICON MakeProcessingIcon(double intensity) const;  // mark filled w/ logo gradient
  void ApplyIcon(HICON icon);               // NIM_MODIFY + take ownership of icon_
  void SetTip(const std::wstring& tip);     // NIM_MODIFY the hover tooltip
  static void CALLBACK RecordTimerProc(HWND, UINT, UINT_PTR, DWORD);
  static void CALLBACK ProcTimerProc(HWND, UINT, UINT_PTR, DWORD);
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

  // Processing-pulse animation (logo-gradient fill); a SEPARATE timer from the
  // recording breath so they never share a frame -- the finalize flow snaps the
  // red off before starting the pulse, and a recording start kills any pulse.
  UINT_PTR proc_timer_ = 0;
  bool processing_ = false;
  bool processing_stop_ = false;   // a stop was requested; end at the next low
  bool proc_reduce_ = false;       // reduced motion -> static fill
  bool proc_unbounded_ = false;    // recording finalize: no 10s ceiling
  unsigned long long proc_start_ms_ = 0;
  int proc_last_cycle_ = 0;

  static TrayIcon* s_record_instance_;  // the single tray; routes BOTH timers
};

#endif  // RUNNER_TRAY_ICON_H_
