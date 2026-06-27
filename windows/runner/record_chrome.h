#ifndef RUNNER_RECORD_CHROME_H_
#define RUNNER_RECORD_CHROME_H_

#include <windows.h>

#include <d2d1_1.h>
#include <dwrite.h>
#include <winrt/base.h>

#include <cstdint>
#include <functional>

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

  // Show the strip below-center of [x,y,w,h] (display-local, top-left LOGICAL
  // points) on monitor [display_id] (HMONITOR round-tripped as int64).
  void Show(int64_t display_id, double x, double y, double w, double h,
            Callbacks cb);
  // Reflect a pause/resume (button label + freeze the timer).
  void SetPaused(bool paused);
  // Tear the strip down (stop / abort / finish / failure).
  void Hide();

 private:
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM) noexcept;
  LRESULT MessageHandler(HWND, UINT, WPARAM, LPARAM) noexcept;
  bool EnsureGraphics();
  void Layout();   // compute the button rects from the strip size
  void Render();
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

  RECT stop_rc_{}, pause_rc_{}, abort_rc_{};  // physical px, client coords

  winrt::com_ptr<ID2D1Factory1> factory_;
  winrt::com_ptr<ID2D1Device> device_;
  winrt::com_ptr<ID2D1DeviceContext> dc_;
  winrt::com_ptr<IDWriteFactory> dwrite_;
  winrt::com_ptr<IDWriteTextFormat> timer_fmt_;
  winrt::com_ptr<IDWriteTextFormat> label_fmt_;
};

#endif  // RUNNER_RECORD_CHROME_H_
