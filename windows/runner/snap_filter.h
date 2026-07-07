#ifndef RUNNER_SNAP_FILTER_H_
#define RUNNER_SNAP_FILTER_H_

#include <cstring>

// The snappable-window ACCEPT decision as pure data, so the filter rules (own
// overlay, tool window, near-zero layered alpha, the NVIDIA overlay class, the
// 40px floor) are unit-testable without live Win32 windows. window_enum.cpp
// fetches these fields then calls Passes(); the result is identical to the
// former inline logic. See [element snap] memory before changing any rule.
namespace snapfilter {

struct Candidate {
  bool visible = false;
  bool iconic = false;
  bool cloaked = false;
  bool is_own_overlay = false;
  bool tool_window = false;        // ex-style WS_EX_TOOLWINDOW
  bool layered = false;            // ex-style WS_EX_LAYERED
  bool has_layered_alpha = false;  // GetLayeredWindowAttributes gave LWA_ALPHA
  int layered_alpha = 255;         // 0..255 (valid only with has_layered_alpha)
  const wchar_t* class_name = L"";
  int width = 0;   // DWM visible bounds width
  int height = 0;  // DWM visible bounds height
};

inline bool Passes(const Candidate& c) {
  if (!c.visible || c.iconic) return false;
  if (c.cloaked) return false;
  if (c.is_own_overlay) return false;
  if (c.tool_window) return false;
  // A layered window faded to (near-)zero alpha is invisible on screen but
  // still enumerable and high in z -- it would swallow every snap beneath it
  // (macOS's alpha > 0.05 filter, ported). Per-pixel (UpdateLayeredWindow)
  // surfaces report no LWA_ALPHA -> treated as opaque.
  if (c.layered && c.has_layered_alpha && c.layered_alpha <= 12) return false;
  // The NVIDIA GeForce overlay: a full-screen always-on-top layer drawing
  // nothing most of the time (ShareX ignore-lists the same class).
  if (wcscmp(c.class_name, L"CEF-OSC-WIDGET") == 0) return false;
  if (c.width < 40 || c.height < 40) return false;
  return true;
}

}  // namespace snapfilter

#endif  // RUNNER_SNAP_FILTER_H_
