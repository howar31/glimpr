#ifndef RUNNER_EXCLUDED_APPS_H_
#define RUNNER_EXCLUDED_APPS_H_

#include <windows.h>

#include <flutter/encodable_value.h>

#include <string>
#include <vector>

#include "capture_mask.h"

struct CaptureFrame;

// The applications the user keeps out of screenshots (Settings > Privacy).
// Windows has no capture-time exclusion for another process's windows, so
// their visible areas are covered (black or blurred) in the captured frame.
// Glimpr's own windows are a different case: a process may take its own
// windows out of every capture, which is what the own-windows setting does.
namespace excluded {

// The stored list (empty while its master switch is off). Read from the
// settings file and cached briefly; safe from any thread.
std::vector<capmask::Entry> List();

// The list as the window-snap code sees it: empty while the session picks a
// recording region, because recordings do not cover anything.
std::vector<capmask::Entry> SnapList();
void SetSnapCoversScreenshot(bool screenshot);

// Whether [hwnd] belongs to an application in [list].
bool IsListed(HWND hwnd, const std::vector<capmask::Entry>& list);

// Whether a display capture leaves [hwnd] out because its owner asked for it.
bool LeftOutOfCapture(HWND hwnd);

// Covers listed applications in monitor captures. Construct before the
// capture, call Resample() after it, then Apply() per frame: a window that
// moved in between is covered at both positions. Inert with an empty list.
class Mask {
 public:
  // [own_windows_cover]: whether this process's own windows count as opaque
  // covers. False where they are capture overlays, which show the screen
  // beneath them.
  explicit Mask(bool own_windows_cover);

  bool active() const { return !list_.empty(); }
  void Resample();

  // [bounds] is the physical virtual-screen rect the frame's pixels span.
  void Apply(CaptureFrame* frame, const RECT& bounds) const;

 private:
  std::vector<capmask::Entry> list_;
  bool own_windows_cover_;
  std::vector<capmask::Window> before_;
  std::vector<capmask::Window> after_;
};

// The own-windows setting. Call on a Glimpr window (Settings, Image Editor,
// pin) once it exists: with the setting on, the window leaves every screen
// capture. [reset_when_off] also clears it, for a live setting change.
void ApplyOwnWindowAffinity(HWND hwnd, bool reset_when_off = false);

// Re-applies the setting to this process's already open windows.
void ReapplyOwnWindowAffinity();

// Running applications that own a visible window, as { id, name, icon }
// (icon = PNG bytes, absent when unavailable), for the Settings pane.
flutter::EncodableList RunningApps();

// { id, name, icon } for stored ids. An id whose file is gone keeps the id as
// its name.
flutter::EncodableList Resolve(const std::vector<std::string>& ids);

}  // namespace excluded

#endif  // RUNNER_EXCLUDED_APPS_H_
