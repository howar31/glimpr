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

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool Register(const std::string& action_key, UINT vk, UINT modifiers,
                const std::string& key_label);
  void Unregister(const std::string& action_key);
  void UnregisterAll();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND owner_ = nullptr;
  int next_id_ = 1;
  std::map<std::string, int> id_for_action_;   // action key -> hotkey id
  std::map<int, std::string> action_for_id_;   // hotkey id -> action key
  std::map<std::string, std::string> labels_;  // action key -> accel label
};

#endif  // RUNNER_HOTKEY_HOST_H_
