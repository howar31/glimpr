#ifndef RUNNER_WINDOW_ENUM_H_
#define RUNNER_WINDOW_ENUM_H_

#include <windows.h>

#include <flutter/encodable_value.h>

#include <string>
#include <vector>

// Snappable top-level windows for the overlay's window-snap, mirroring the
// macOS snappableWindows. Windows snap is RECTANGULAR (the architecture
// checkpoint fixes the Windows overlay as opaque + rectangular), so this only
// provides window RECTS -- no per-window alpha-shape mask.
namespace win_enum {

// Visible, non-minimized, non-cloaked top-level windows intersecting [mon],
// front-to-back, as display-local LOGICAL rects { x, y, w, h, title, app,
// windowNumber }. Only the freeze [overlays] (our top-most covers) are excluded;
// glimpr's OWN normal windows (Settings / editor) ARE snappable, matching macOS
// snappableWindows.
flutter::EncodableList SnappableWindows(HMONITOR mon,
                                        const std::vector<HWND>& overlays);

// Title / owning-process name of a top-level window (UTF-8), shared by the
// snap list above and the direct window capture's reply metadata.
std::string WindowTitle(HWND hwnd);
std::string ProcessName(HWND hwnd);

// A window's on-screen bounds (DWM extended frame; physical, virtual-screen).
RECT VisibleWindowBounds(HWND hwnd);

// The frontmost snappable top-level window under the PHYSICAL point (the same
// visibility/tool-window/size filters as SnappableWindows), skipping our own
// freeze [overlays]. Null when nothing real is under the point. Used by the
// element snap to scope its UIA query to the window the user actually aims at
// (a global hit test would return our topmost overlay instead).
HWND TopWindowAt(POINT pt, const std::vector<HWND>& overlays);

}  // namespace win_enum

#endif  // RUNNER_WINDOW_ENUM_H_
