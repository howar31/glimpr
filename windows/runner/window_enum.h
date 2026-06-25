#ifndef RUNNER_WINDOW_ENUM_H_
#define RUNNER_WINDOW_ENUM_H_

#include <windows.h>

#include <flutter/encodable_value.h>

#include <vector>

// Snappable top-level windows for the overlay's window-snap, mirroring the
// macOS snappableWindows. Windows snap is RECTANGULAR (the architecture
// checkpoint fixes the Windows overlay as opaque + rectangular), so this only
// provides window RECTS -- no per-window alpha-shape mask.
namespace win_enum {

// Visible, non-minimized, non-cloaked top-level windows intersecting [mon],
// front-to-back, as display-local LOGICAL rects { x, y, w, h, title, app,
// windowNumber }. [control] + [overlays] (our own HWNDs) are excluded.
flutter::EncodableList SnappableWindows(HMONITOR mon, HWND control,
                                        const std::vector<HWND>& overlays);

}  // namespace win_enum

#endif  // RUNNER_WINDOW_ENUM_H_
