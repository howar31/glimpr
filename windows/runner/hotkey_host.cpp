#include "hotkey_host.h"

#include <flutter/standard_method_codec.h>

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
// RegisterHotKey fsModifiers add-on: do not re-fire while the keys stay held.
constexpr UINT kModNoRepeat = 0x4000;  // MOD_NOREPEAT

// Safe arg readers (match the int32/int64 handling used elsewhere in the runner).
std::string GetString(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (auto p = std::get_if<std::string>(&it->second)) return *p;
  }
  return std::string();
}

int GetInt(const EncodableMap& map, const char* key, int dflt) {
  auto it = map.find(EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (auto p = std::get_if<int32_t>(&it->second)) return *p;
    if (auto p = std::get_if<int64_t>(&it->second)) return static_cast<int>(*p);
  }
  return dflt;
}
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
  } else {
    result->NotImplemented();
  }
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
