#ifndef RUNNER_OVERLAY_MANAGER_H_
#define RUNNER_OVERLAY_MANAGER_H_

#include <windows.h>

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include "clipboard_channel.h"
#include "element_snap.h"
#include "encode_channel.h"
#include "sound_channel.h"
#include "live_frame_source.h"
#include "overlay_window.h"

// An element-snap UIA reply finished on the worker thread; the platform thread
// completes the pending MethodResults (FlutterWindow routes it here).
#define WM_GLIMPR_ELSNAP (WM_APP + 4)

// The overlay host process's way out to the main process. Everything the
// overlay needs from the resident side (editor, pins, Settings, record
// control, tray) is a one-way message; nothing waits for a reply.
class OverlayHostLink {
 public:
  virtual ~OverlayHostLink() = default;
  // Proxy a main-process-bound glimpr/capture method with its arguments.
  virtual void Call(const std::string& method,
                    const flutter::EncodableValue& args) = 0;
  // The capture session fully drained: tell the main process and exit.
  virtual void EndSession() = 0;
  virtual DWORD main_pid() const = 0;
};

// Owns the per-display overlay windows + their Flutter engines and drives the
// capture-then-show / dismiss lifecycle, the single-authority cursor poll, the
// drawing lock, and the cross-engine broadcast. The Windows analogue of the
// macOS OverlayManager (OverlayKit.swift) + the capture-orchestration half of
// CaptureController. Engine lifecycle = LAZY create on first capture, then
// resident-warm (hidden between captures) -- NO macOS warm-at-launch hack.
// One instance, owned by the overlay host process (overlay_host.cpp), which
// exits after every capture session -- see TeardownUnits.
class OverlayManager {
 public:
  // [marshal_hwnd] receives WM_GLIMPR_ELSNAP (the host's message window).
  OverlayManager(const flutter::DartProject& project, HWND marshal_hwnd,
                 OverlayHostLink* link);
  ~OverlayManager();

  OverlayManager(const OverlayManager&) = delete;
  OverlayManager& operator=(const OverlayManager&) = delete;

  // The native capture trigger (control engine's glimpr/capture beginCapture).
  // [pinOnly] runs the pin-only confirm flow. [liveSelect] (the recording region
  // picker) presents a TRUE-TRANSPARENT overlay over the LIVE screen (not a
  // frozen screenshot) + starts a per-display live WGC feed for the loupe --
  // full macOS parity.
  void BeginCapture(bool pin_only, bool live_select);

  // Pre-create the per-display overlay engines/windows ahead of the first
  // capture so that capture is instant (the engine boot is the cold-start cost).
  // Driven by FlutterWindow on a deferred post-launch timer (off the launch
  // critical path). Idempotent + cheap to call again (engines already built are
  // reused); a capture during the delay just lazy-creates them itself, and the
  // two never race (both run on the UI thread).
  void WarmUp();

  // A record hotkey pressed while a record-select picker is in flight: relay
  // onRecordSelectHotkey to EVERY overlay engine so each resurfaces / cancels its
  // picker per its own state (the shared Dart decides). Mirrors the macOS
  // relayRecordSelectHotkey. Called from the control engine's capture channel.
  void RelayRecordSelectHotkey();

  // Routed from FlutterWindow::MessageHandler on WM_GLIMPR_ELSNAP: completes
  // the element-snap MethodResults the UIA worker finished, on the platform
  // thread (the RunCaptureAsync marshal idiom).
  void OnElementSnapDone();

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
    std::unique_ptr<SoundChannel> sound;
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
  // Live record-select: the same dict MINUS the frozen pixels (the overlay is
  // transparent over the live screen; Dart uses a transparent stub base + the
  // live loupe feed). Geometry + cursor + snappable windows only.
  EncodableMap BuildLiveDisplayDict(HMONITOR mon, bool is_cursor,
                                    POINT cursor_global);
  // Stop + clear the per-display live loupe feeds (idempotent).
  void EndLiveSelect();
  std::vector<HWND> OverlayHwnds() const;  // our own windows, excluded from snap

  // ---- cursor poll / active display --------------------------------------
  void StartCursorTracking();
  void StopCursorTracking();
  void TickCursor();
  void SetActiveDisplay(int64_t display_id, POINT global);
  static void CALLBACK TimerProc(HWND, UINT, UINT_PTR, DWORD);

  // End the session shortly after a dismiss by exiting this process (the main
  // process then starts a fresh warm host). Two reasons, both engine-lifetime:
  // (1) a resident overlay engine that has RENDERED a captured frame leaves
  // other apps' WinUI3 content islands (e.g. File Explorer's tab / address bar
  // -- Microsoft.UI.Content.DesktopChildSiteBridge) unable to receive
  // mouse/pointer input until the engine is gone (legacy USER32 children +
  // keyboard use other delivery paths, so they keep working -- which is why
  // every queryable input state read clean); (2) destroying such an engine
  // in-process never returns its GPU memory (flutter/flutter#193080), so only a
  // process exit gives it back. Deferred via a one-shot timer so the exit never
  // happens inside the dismissOverlay channel handler that triggers it.
  void TeardownUnits();
  static void CALLBACK TeardownProc(HWND, UINT, UINT_PTR, DWORD);

  // Watchdog for the capture-serialization guard: if a presented display's
  // engine never fires overlayReady (a wedged present chain), presenting_
  // would stay set and silently drop every capture until a dismiss. The
  // watchdog force-releases the guard after a few seconds.
  void ArmPresentWatchdog();
  void ReleaseStuckPresentGuard();
  static void CALLBACK PresentWatchdogProc(HWND, UINT, UINT_PTR, DWORD);

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
  HWND marshal_hwnd_ = nullptr;
  OverlayHostLink* link_ = nullptr;  // not owned; outlives this
  std::map<int64_t, Unit> units_;

  // Freeze-retained HDR base per display (HDR monitor + the hdr_screenshot
  // setting on at capture): the fp16 scRGB frame the annotated export's HDR
  // sibling is composited from (encodeHdrRegion). Latest capture generation
  // only -- deeper layer-stack layers get no HDR sibling. Overwritten each
  // BeginCapture, released in TeardownUnits.
  struct HdrBase {
    std::vector<uint8_t> f16;  // RGBA16F, stride = w * 8
    uint32_t w = 0, h = 0;
    float sdr_white_nits = 240.0f;
    int64_t gen = 0;
  };
  std::map<int64_t, HdrBase> hdr_bases_;
  int64_t hdr_gen_ = 0;

  // Live record-select state: one live WGC loupe feed per display while a
  // transparent picker session is up (empty otherwise).
  bool live_select_ = false;
  std::map<int64_t, std::unique_ptr<LiveFrameSource>> live_sources_;

  // Precise element snap: the UIA worker (lazy -- most sessions never use it)
  // and the replies finished on the worker, drained by OnElementSnapDone on
  // the platform thread. The host is declared LAST so its destructor (which
  // joins the worker, flushing pending replies into the queue) runs while the
  // queue and mutex are still alive.
  std::mutex elsnap_mutex_;
  std::vector<std::pair<std::shared_ptr<flutter::MethodResult<EncodableValue>>,
                        EncodableValue>>
      elsnap_done_;
  std::unique_ptr<elsnap::Host> element_snap_;

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
  UINT_PTR present_watchdog_ = 0;  // one-shot stuck-present release (see above)

  UINT_PTR teardown_timer_ = 0;  // one-shot post-dismiss session end
  // An annotated export runs async on an overlay engine AFTER the overlay hides;
  // a large capture's compose+encode+save+copy can outlast the 250ms teardown.
  // Exiting mid-export aborts the save/clipboard, so the export
  // holds this flag and the teardown defers until it clears (bounded so a wedged
  // export can never leave the WinUI3-island repair permanently undone).
  bool export_busy_ = false;
  int teardown_defer_count_ = 0;

  static OverlayManager* instance_;  // single owner; routes the timer callback
};

#endif  // RUNNER_OVERLAY_MANAGER_H_
