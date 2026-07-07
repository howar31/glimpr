#ifndef RUNNER_CAPTURE_KEY_RULE_H_
#define RUNNER_CAPTURE_KEY_RULE_H_

#include <windows.h>

// When a key event should COMMIT the hotkey recorder's capture. PrintScreen
// (VK_SNAPSHOT) is delivered as a key-UP only; every other key commits on
// key-DOWN, skipping auto-repeat so a held key fires once. Pure -- extracted
// from HotkeyHost::HandleCaptureMessage so the rule is unit-testable.
inline bool ShouldCommitCaptureKey(UINT vk, bool is_down, bool is_up,
                                   bool is_repeat) {
  return (vk == VK_SNAPSHOT) ? is_up : (is_down && !is_repeat);
}

#endif  // RUNNER_CAPTURE_KEY_RULE_H_
