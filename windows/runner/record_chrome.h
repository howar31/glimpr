#ifndef RUNNER_RECORD_CHROME_H_
#define RUNNER_RECORD_CHROME_H_

#include <windows.h>

#include <d2d1_1.h>
#include <dwrite.h>
#include <winrt/base.h>

#include <cstdint>
#include <functional>
#include <vector>

// The recording control strip: a layered, top-most, Direct2D window showing a
// recording-red dot + elapsed timer + Stop / Pause-Resume / Abort buttons. It is
// EXCLUDED from capture (SetWindowDisplayAffinity WDA_EXCLUDEFROMCAPTURE) so it
// never appears in the recording. The macOS RecordingChrome strip analogue. v1 =
// the strip only (the region border, countdown HUD and cross-display scrims are
// follow-on work). One instance, owned by RecordChannel; driven on the platform
// thread.
class RecordChrome {
 public:
  struct Callbacks {
    std::function<void()> on_stop;
    std::function<void()> on_pause_toggle;
    std::function<void()> on_abort;
  };

  RecordChrome();
  ~RecordChrome();
  RecordChrome(const RecordChrome&) = delete;
  RecordChrome& operator=(const RecordChrome&) = delete;

  // Show the chrome for a recording of [x,y,w,h] (display-local, top-left LOGICAL
  // points) on monitor [display_id] (HMONITOR round-tripped as int64): the control
  // strip below-center, plus a red border around the rect when [border] (region /
  // window modes), plus a dim scrim over every OTHER display when [scrim].
  void Show(int64_t display_id, double x, double y, double w, double h,
            bool border, bool scrim, int max_duration_sec, Callbacks cb);
  // Reflect a pause/resume (button label + freeze the timer).
  void SetPaused(bool paused);
  // Show a pre-recording countdown HUD centred on the target ([x,y,w,h] display-
  // local logical; the monitor centre when w/h are 0). Calls [on_done] when it
  // reaches 0 or [on_cancel] on a click. Shown before the recording starts.
  void ShowCountdown(int64_t display_id, double x, double y, double w, double h,
                     int seconds, std::function<void()> on_done,
                     std::function<void()> on_cancel);
  // Tear the strip + border + scrims + countdown down.
  void Hide();

 private:
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM) noexcept;
  static void EnsureClass();  // register the shared window class once
  LRESULT MessageHandler(HWND, UINT, WPARAM, LPARAM) noexcept;
  bool EnsureGraphics();
  void Layout();   // compute the button rects from the strip size
  void Render();
  void RenderCountdown();
  void FinishCountdown(bool done);  // true = reached 0, false = cancelled
  // Draw the recorded-rect border (rounded red edge + glow + viewfinder corner
  // brackets) into a click-through overlay window, faithful to macOS.
  void ShowBorder(int rx, int ry, int rw, int rh);  // recorded rect, physical px
  // Blit a finished D2D target bitmap to a layered window at (x,y).
  void PresentLayered(HWND hwnd, ID2D1Bitmap1* target, int x, int y, UINT W,
                      UINT H);
  int HitTest(POINT client) const;  // 0 none, 1 stop, 2 pause, 3 abort

  HWND hwnd_ = nullptr;
  Callbacks cb_;
  double scale_ = 1.0;
  int win_x_ = 0, win_y_ = 0, win_w_ = 0, win_h_ = 0;  // physical px
  ULONGLONG start_ms_ = 0;      // GetTickCount64 at show
  ULONGLONG paused_at_ = 0;     // tick when paused (0 = running)
  ULONGLONG paused_total_ = 0;  // accumulated paused ms
  bool paused_ = false;
  int hover_ = 0;  // hovered button (0 none)
  bool tracking_leave_ = false;
  int max_duration_sec_ = 0;     // > 0 draws the auto-stop progress rail
  bool dragging_ = false;        // the strip is being dragged
  POINT drag_off_{};             // cursor-screen - window-origin at drag start
  bool abort_armed_ = false;     // Abort is in its confirm step
  ULONGLONG abort_arm_ms_ = 0;   // when Abort was armed (auto-disarms after 3s)

  RECT stop_rc_{}, pause_rc_{}, abort_rc_{};  // physical px, client coords

  HWND border_hwnd_ = nullptr;        // red outline around the recorded rect
  std::vector<HWND> scrim_hwnds_;     // dim overlays on the OTHER displays

  HWND cd_hwnd_ = nullptr;            // countdown HUD window
  int cd_remaining_ = 0;
  int cd_x_ = 0, cd_y_ = 0, cd_w_ = 0, cd_h_ = 0;  // physical px
  std::function<void()> cd_done_;
  std::function<void()> cd_cancel_;

  winrt::com_ptr<ID2D1Factory1> factory_;
  winrt::com_ptr<ID2D1Device> device_;
  winrt::com_ptr<ID2D1DeviceContext> dc_;
  winrt::com_ptr<IDWriteFactory> dwrite_;
  winrt::com_ptr<IDWriteTextFormat> timer_fmt_;
  winrt::com_ptr<IDWriteTextFormat> label_fmt_;
  winrt::com_ptr<IDWriteTextFormat> cd_fmt_;  // big countdown number
};

#endif  // RUNNER_RECORD_CHROME_H_
