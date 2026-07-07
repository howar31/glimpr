#include "hotkey_host.h"

#include <flutter/standard_method_codec.h>

#include "capture_key_rule.h"
#include "channel_args.h"

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace chanarg;

namespace {
// RegisterHotKey fsModifiers add-on: do not re-fire while the keys stay held.
constexpr UINT kModNoRepeat = 0x4000;  // MOD_NOREPEAT

// RegisterHotKey fsModifiers bits, reused as the capture modifier mask sent to
// Dart (which decodes them with modifiersFromWin32Mask).
constexpr UINT kModAlt = 0x0001;      // MOD_ALT
constexpr UINT kModControl = 0x0002;  // MOD_CONTROL
constexpr UINT kModShift = 0x0004;    // MOD_SHIFT
constexpr UINT kModWin = 0x0008;      // MOD_WIN
}  // namespace

HotkeyHost::HotkeyHost(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/hotkeys",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

HotkeyHost::~HotkeyHost() { UnregisterAll(); }

void HotkeyHost::Fire(int hotkey_id) {
  auto it = action_for_id_.find(hotkey_id);
  if (it == action_for_id_.end()) return;
  channel_->InvokeMethod("onHotkey",
                         std::make_unique<EncodableValue>(it->second));
}

void HotkeyHost::FireAction(const std::string& action_key) {
  channel_->InvokeMethod("onHotkey",
                         std::make_unique<EncodableValue>(action_key));
}

std::string HotkeyHost::AcceleratorLabel(const std::string& action_key) {
  auto it = labels_.find(action_key);
  return it == labels_.end() ? std::string() : it->second;
}

void HotkeyHost::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "register") {
    if (!args) {
      result->Success(EncodableValue(false));
      return;
    }
    std::string id = GetString(*args, "id");
    UINT vk = static_cast<UINT>(GetInt(*args, "vk", 0));
    UINT modifiers = static_cast<UINT>(GetInt(*args, "modifiers", 0));
    std::string label = GetString(*args, "keyLabel");
    bool ok = Register(id, vk, modifiers, label);
    result->Success(EncodableValue(ok));
  } else if (method == "unregister") {
    if (args) Unregister(GetString(*args, "id"));
    result->Success();
  } else if (method == "unregisterAll") {
    UnregisterAll();
    result->Success();
  } else if (method == "beginCaptureKeys") {
    capturing_ = true;
    result->Success();
  } else if (method == "endCaptureKeys") {
    capturing_ = false;
    result->Success();
  } else {
    result->NotImplemented();
  }
}

bool HotkeyHost::HandleCaptureMessage(UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  const bool is_down = (message == WM_KEYDOWN || message == WM_SYSKEYDOWN);
  const bool is_up = (message == WM_KEYUP || message == WM_SYSKEYUP);
  if (!is_down && !is_up) return false;
  const UINT vk = static_cast<UINT>(wparam);
  // A modifier key alone never completes a combo -- consume and wait for a main
  // key (its state is read via GetKeyState when a main key arrives).
  switch (vk) {
    case VK_SHIFT:
    case VK_CONTROL:
    case VK_MENU:
    case VK_LSHIFT:
    case VK_RSHIFT:
    case VK_LCONTROL:
    case VK_RCONTROL:
    case VK_LMENU:
    case VK_RMENU:
    case VK_LWIN:
    case VK_RWIN:
      return true;
  }
  if (vk == VK_ESCAPE) {
    if (is_down) channel_->InvokeMethod("onCaptureCancel", nullptr);
    return true;
  }
  // Commit rule (PrintScreen on up, others on down, no auto-repeat) lives in
  // ShouldCommitCaptureKey so it is unit-testable; bit 30 = auto-repeat.
  const bool is_repeat = is_down && (lparam & (1LL << 30)) != 0;
  if (ShouldCommitCaptureKey(vk, is_down, is_up, is_repeat)) EmitCaptureKey(vk);
  return true;  // consume every key while capturing
}

void HotkeyHost::EmitCaptureKey(UINT vk) {
  UINT mods = 0;
  if (GetKeyState(VK_SHIFT) & 0x8000) mods |= kModShift;
  if (GetKeyState(VK_CONTROL) & 0x8000) mods |= kModControl;
  if (GetKeyState(VK_MENU) & 0x8000) mods |= kModAlt;
  if ((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) {
    mods |= kModWin;
  }
  // Availability probe at RECORD time: our own hotkeys are paused during
  // capture, so a momentary RegisterHotKey fails only if ANOTHER app or the OS
  // already owns this combo (e.g. Win+PrintScreen). Lets Settings flag the combo
  // + block Apply immediately, like an internal duplicate -- instead of silently
  // saving an unusable binding. Uses a fixed probe id (well clear of real ones).
  bool available = false;
  constexpr int kProbeId = 0xBFFF;
  if (RegisterHotKey(owner_, kProbeId, mods | kModNoRepeat, vk)) {
    UnregisterHotKey(owner_, kProbeId);
    available = true;
  }
  channel_->InvokeMethod(
      "onCaptureKey",
      std::make_unique<EncodableValue>(EncodableMap{
          {EncodableValue("vk"), EncodableValue(static_cast<int>(vk))},
          {EncodableValue("modifiers"), EncodableValue(static_cast<int>(mods))},
          {EncodableValue("available"), EncodableValue(available)},
      }));
}

bool HotkeyHost::Register(const std::string& action_key, UINT vk, UINT modifiers,
                          const std::string& key_label) {
  if (action_key.empty() || vk == 0) return false;
  // Replace any existing registration for this action.
  Unregister(action_key);
  int id = next_id_++;
  if (!RegisterHotKey(owner_, id, modifiers | kModNoRepeat, vk)) {
    return false;  // e.g. ERROR_HOTKEY_ALREADY_REGISTERED
  }
  id_for_action_[action_key] = id;
  action_for_id_[id] = action_key;
  labels_[action_key] = key_label;
  return true;
}

void HotkeyHost::Unregister(const std::string& action_key) {
  auto it = id_for_action_.find(action_key);
  if (it == id_for_action_.end()) return;
  UnregisterHotKey(owner_, it->second);
  action_for_id_.erase(it->second);
  id_for_action_.erase(it);
  labels_.erase(action_key);
}

void HotkeyHost::UnregisterAll() {
  for (const auto& entry : id_for_action_) {
    UnregisterHotKey(owner_, entry.second);
  }
  id_for_action_.clear();
  action_for_id_.clear();
  labels_.clear();
}
