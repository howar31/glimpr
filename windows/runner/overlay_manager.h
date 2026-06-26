#ifndef RUNNER_OVERLAY_MANAGER_H_
#define RUNNER_OVERLAY_MANAGER_H_

#include <windows.h>

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

#include "clipboard_channel.h"
#include "encode_channel.h"
#include "overlay_window.h"

// Owns the per-display overlay windows + their Flutter engines and drives the
// capture-then-show / dismiss lifecycle, the single-authority cursor poll, the
// drawing lock, and the cross-engine broadcast. The Windows analogue of the
// macOS OverlayManager (OverlayKit.swift) + the capture-orchestration half of
// CaptureController. Engine lifecycle = LAZY create on first capture, then
// resident-warm (hidden between captures) -- NO macOS warm-at-launch hack.
// One instance, owned by FlutterWindow.
class OverlayManager {
 public:
  OverlayManager(const flutter::DartProject& project, HWND control_hwnd);
  ~OverlayManager();

  OverlayManager(const OverlayManager&) = delete;
  OverlayManager& operator=(const OverlayManager&) = delete;

  // The native capture trigger (control engine's glimpr/capture beginCapture).
  // Captures every display and presents the freeze overlay. [pinOnly] runs the
  // pin-only confirm flow (pin no-ops on Windows for now); [liveSelect] (the
  // recording picker) is deferred to S6 and ignored.
  void BeginCapture(bool pin_only, bool live_select);

  // Pre-create the per-display overlay engines/windows ahead of the first
  // capture so that capture is instant (the engine boot is the cold-start cost).
  // Driven by FlutterWindow on a deferred post-launch timer (off the launch
  // critical path). Idempotent + cheap to call again (engines already built are
  // reused); a capture during the delay just lazy-creates them itself, and the
  // two never race (both run on the UI thread).
  void WarmUp();

 private:
  using EncodableValue = flutter::EncodableValue;
  using EncodableMap = flutter::EncodableMap;
  template <typename T>
  using MethodChannel = flutter::MethodChannel<T>;

  struct Unit {
    std::unique_ptr<OverlayWindow> window;
    int64_t display_id = 0;  // HMONITOR round-tripped as intptr
    std::unique_ptr<MethodChannel<EncodableValue>> role;
    std::unique_ptr<MethodChannel<EncodableValue>> capture;
    std::unique_ptr<MethodChannel<EncodableValue>> overlay;  // native -> Dart
    std::unique_ptr<MethodChannel<EncodableValue>> fonts;
    std::unique_ptr<ClipboardChannel> clipboard;
    std::unique_ptr<EncodeChannel> encode;
  };

  // ---- lifecycle ----------------------------------------------------------
  // Ensure exactly one warm Unit per CURRENT monitor (lazy-create on first
  // call; tear down units for detached monitors). Safety net before each
  // capture and the hot-plug response. Simpler than macOS: Windows creates
  // engines at runtime, so there is no warm-spare pool.
  void SyncUnitsToScreens();
  Unit* EnsureUnit(HMONITOR mon);
  Unit* UnitFor(int64_t display_id);
  void RegisterUnitChannels(Unit& unit);

  // ---- present / show / dismiss ------------------------------------------
  void PresentBegin(int64_t cursor_display_id);
  void PresentFrame(int64_t display_id, EncodableMap dict, bool pin_only,
                    bool live_select);
  void Show(int64_t display_id);
  void Hide(int64_t display_id);
  void DismissAll();
  // Takes the frame BY VALUE so the BGRA buffer is MOVED into the reply (a 4K
  // display is ~33 MB -- never copied).
  EncodableMap BuildDisplayDict(HMONITOR mon, struct CaptureFrame frame,
                                bool is_cursor, POINT cursor_global);
  std::vector<HWND> OverlayHwnds() const;  // our own windows, excluded from snap

  // ---- cursor poll / active display --------------------------------------
  void StartCursorTracking();
  void StopCursorTracking();
  void TickCursor();
  void SetActiveDisplay(int64_t display_id, POINT global);
  static void CALLBACK TimerProc(HWND, UINT, UINT_PTR, DWORD);

  // ---- drawing lock / warp / cursor hide ---------------------------------
  void SetDrawingLock(int64_t display_id_or_zero);
  void ConfineToDrawingDisplay();
  void WarpCursor(double logical_global_x, double logical_global_y);
  void SetCursorHidden(bool hidden);

  // ---- broadcast ----------------------------------------------------------
  void BroadcastEditorState(int64_t from_display_id, const EncodableMap& args);

  // ---- the overlay engine's glimpr/capture handler ------------------------
  void HandleOverlayCapture(
      int64_t display_id,
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result);

  flutter::DartProject project_;
  HWND control_hwnd_ = nullptr;
  std::map<int64_t, Unit> units_;

  int64_t key_display_id_ = 0;     // cursor display at capture (takes focus)
  int64_t active_display_id_ = 0;  // current active (cursor poll authority)
  int64_t drawing_lock_id_ = 0;    // non-zero while a draw/crop drag is locked
  bool cursor_hidden_ = false;
  UINT_PTR cursor_timer_ = 0;
  // Capture serialization: true from a capture's present until ALL its presented
  // displays are shown. A re-trigger while true is DROPPED, so the async present
  // -> overlayReady -> Show chains never overlap (mirrors macOS, where
  // triggerCapture is serialized on the main actor; rapid overlap was the crash).
  // Deliberate layer-stacking still works: once the overlay is fully up the guard
  // clears and a re-press stacks/replaces normally. pending_shows_ counts the
  // displays still awaiting Show (each presented display's overlayReady fires once).
  bool presenting_ = false;
  int pending_shows_ = 0;

  static OverlayManager* instance_;  // single owner; routes the timer callback
};

#endif  // RUNNER_OVERLAY_MANAGER_H_
