#ifndef RUNNER_ELEMENT_SNAP_H_
#define RUNNER_ELEMENT_SNAP_H_

#include <windows.h>

#include <flutter/encodable_value.h>

#include <functional>
#include <optional>
#include <vector>

// UI Automation element snap for the capture overlay's "precise element snap"
// mode -- the Windows analogue of the macOS AX path (ElementSnap.swift). The
// Dart side is shared and already wired; this answers elementSnapAt.
//
// The load-bearing gotcha carries over from the mac: the freeze overlay is a
// full-screen TOPMOST hit-testable window, so a global UIA ElementFromPoint
// would always return OUR OWN overlay. Instead the query resolves the frontmost
// foreign top-level window under the point (excluding our overlay windows),
// then descends THAT window's UIA tree to the element at the point. If our own
// window (Settings / editor / pin) is the visual top, the query returns null
// and Dart whole-window-snaps it -- the owner-decided mac behavior.
namespace elsnap {

// A dedicated UIA worker: one MTA thread owning a single CUIAutomation client
// (UIA clients must not run on their own process's UI thread, and creating the
// client per query costs milliseconds). Queries are serialized FIFO; every
// request gets a reply (the Dart caller awaits it). Replies are invoked ON THE
// WORKER thread -- the caller marshals back to the platform thread.
class Host {
 public:
  using Reply = std::function<void(std::optional<flutter::EncodableMap>)>;

  Host();
  ~Host();

  Host(const Host&) = delete;
  Host& operator=(const Host&) = delete;

  // The element under the display-local LOGICAL point on [mon]. [walk]: 0 = at
  // the point, +N = N levels up the ancestry (grow), -N = N levels back down
  // toward the point (shrink). [exclude] = our own overlay HWNDs. Null reply =
  // no element / own window on top / target hung (Dart falls back to window
  // snap).
  void Query(HMONITOR mon, double logical_x, double logical_y, int walk,
             std::vector<HWND> exclude, Reply reply);

 private:
  struct Impl;
  Impl* impl_;
};

}  // namespace elsnap

#endif  // RUNNER_ELEMENT_SNAP_H_
