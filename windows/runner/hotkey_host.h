#ifndef RUNNER_HOTKEY_HOST_H_
#define RUNNER_HOTKEY_HOST_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <map>
#include <memory>
#include <string>

// Hosts the "glimpr/hotkeys" channel: Win32 RegisterHotKey global hotkeys.
// Dart's WindowsHotkeyRegistrar sends {id, vk, modifiers, keyLabel}; a fired
// hotkey (WM_HOTKEY, routed from FlutterWindow) invokes onHotkey(actionKey)
// back to Dart. The macOS analogue is HotkeyController (Carbon). In-runner.
class HotkeyHost {
 public:
  HotkeyHost(flutter::BinaryMessenger* messenger, HWND owner);
  ~HotkeyHost();

  HotkeyHost(const HotkeyHost&) = delete;
  HotkeyHost& operator=(const HotkeyHost&) = delete;

  // WM_HOTKEY wparam -> fire the bound action to Dart.
  void Fire(int hotkey_id);
  // Fire by action key (the tray menu shares the Dart dispatcher).
  void FireAction(const std::string& action_key);
  // The formatted accelerator hint for a menu item, e.g. "Ctrl+Alt+Win+1", or "".
  std::string AcceleratorLabel(const std::string& action_key);

  // ---- Recorder key capture (Settings) -------------------------------------
  // Flutter's Windows engine drops PrintScreen (orphan key-up) and the OS
  // reserves the Win key, so the Settings recorder cannot read these from
  // Flutter key events. While capturing, FlutterWindow subclasses its view and
  // routes key messages here; a completed combo -> onCaptureKey(vk, modifiers),
  // Escape -> onCaptureCancel. Capture is for RECORDING only; triggering still
  // uses RegisterHotKey (the OS detects the combo, no raw keys needed).
  bool Capturing() const { return capturing_; }
  // Handle a key message during capture. Returns true when consumed (always
  // while capturing) so Flutter never sees the key mid-record.
  bool HandleCaptureMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool Register(const std::string& action_key, UINT vk, UINT modifiers,
                const std::string& key_label);
  void Unregister(const std::string& action_key);
  void UnregisterAll();
  void EmitCaptureKey(UINT vk);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND owner_ = nullptr;
  bool capturing_ = false;  // Settings recorder key-capture session active
  int next_id_ = 1;
  std::map<std::string, int> id_for_action_;   // action key -> hotkey id
  std::map<int, std::string> action_for_id_;   // hotkey id -> action key
  std::map<std::string, std::string> labels_;  // action key -> accel label
};

#endif  // RUNNER_HOTKEY_HOST_H_
