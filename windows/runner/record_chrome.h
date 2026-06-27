#ifndef RUNNER_RECORD_CHROME_H_
#define RUNNER_RECORD_CHROME_H_

#include <windows.h>

#include <d2d1_1.h>
#include <dwrite.h>
#include <winrt/base.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// The recording control strip: a layered, top-most, Direct2D window showing a
// breathing recording-red dot + elapsed timer + size/frames readout + Pause /
// Abort / Finish buttons, plus the recorded-rect border, cross-display + outside-
// rect scrims, and the pre-recording countdown HUD. EXCLUDED from capture
// (SetWindowDisplayAffinity WDA_EXCLUDEFROMCAPTURE) so it never appears in the
// recording. The macOS RecordingChrome analogue: same visuals + behaviour
// (themed light/dark, localized labels, dynamic button widths), implemented with
// platform-native Win32 + Direct2D. One instance, owned by RecordChannel; driven
// on the platform thread.
class RecordChrome {
 public:
  struct Callbacks {
    std::function<void()> on_stop;
    std::function<void()> on_pause_toggle;
    std::function<void()> on_abort;
  };

  // Localized strip / countdown labels pushed from Dart (the runner C++ is
  // ASCII-only / cp950, so it cannot hold the zh strings). Defaults are English
  // so the strip works before the boot-time push lands.
  struct Labels {
    std::wstring finish = L"Finish";
    std::wstring pause = L"Pause";
    std::wstring resume = L"Resume";
    std::wstring abort = L"Abort";
    std::wstring confirm = L"Confirm?";
    std::wstring frames = L"frames";
    std::wstring countdown_cancel = L"Click to cancel";
  };

  RecordChrome();
  ~RecordChrome();
  RecordChrome(const RecordChrome&) = delete;
  RecordChrome& operator=(const RecordChrome&) = delete;

  // Show the chrome for a recording of [x,y,w,h] (display-local, top-left LOGICAL
  // points) on monitor [display_id] (HMONITOR round-tripped as int64): the control
  // strip below-center, plus a red border around the rect when [border] (region /
  // window modes), plus a dim scrim over EVERY OTHER display AND the area OUTSIDE
  // the rect on the recording display (region/window) when [scrim]. The strip's
  // readout shows the mp4 file size polled from [output_path], or -- when [gif] --
  // the GIF frame count from [frame_count] (GIF buffers until finalize).
  void Show(int64_t display_id, double x, double y, double w, double h,
            bool border, bool scrim, int max_duration_sec, bool gif,
            const std::string& output_path, std::function<int()> frame_count,
            Callbacks cb);
  // Replace the localized strip / countdown labels (pushed once from Dart at
  // boot). Takes effect on the next Show; safe to call any time.
  void SetLabels(const Labels& labels) { labels_ = labels; }
  // Reflect a pause/resume (button label + freeze the timer).
  void SetPaused(bool paused);
  // Show a pre-recording countdown HUD centred on the target ([x,y,w,h] display-
  // local logical; the monitor centre when w/h are 0). Also shows the recorded-
  // rect frame ([border]/[scrim]) so it is visible DURING the countdown (macOS
  // parity) and persists into recording. Calls [on_done] when it reaches 0 or
  // [on_cancel] on a click.
  void ShowCountdown(int64_t display_id, double x, double y, double w, double h,
                     int seconds, bool border, bool scrim,
                     std::function<void()> on_done,
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
  // DirectWrite width of [s] under [fmt], in physical px (the formats are sized
  // at the monitor scale). Used to reserve the timer + size-readout columns.
  float MeasureWidth(IDWriteTextFormat* fmt, const wchar_t* s);
  void RenderCountdown();
  void FinishCountdown(bool done);  // true = reached 0, false = cancelled
  // Tear ONLY the strip + countdown HUD; keep the frame overlays (seamless
  // countdown -> recording).
  void TearStrip();
  // Create the recorded-rect frame overlays (outside-rect + other-display
  // scrims, red border). Idempotent via frame_up_, so the countdown and the
  // strip Show share one frame.
  void CreateFrameOverlays(HMONITOR mon, const MONITORINFO& mi, double x,
                           double y, double w, double h, bool border,
                           bool scrim);
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
  bool gif_ = false;             // GIF -> show frame count; mp4 -> show file size
  std::wstring out_path_w_;      // widened output path (mp4 on-disk size poll)
  std::function<int()> frame_count_;  // current GIF frame count (gif only)
  int timer_x_ = 0, size_x_ = 0, div_x_ = 0;  // left-cluster x origins (phys px)
  int timer_w_ = 0, size_w_ = 0;              // reserved readout widths (phys px)
  int pause_w_ = 0, abort_w_ = 0, stop_w_ = 0;  // per-button widths (phys px)
  Labels labels_;                // localized labels (Dart-pushed; English default)
  bool light_ = false;           // strip follows the system light/dark theme
  std::wstring last_detail_;      // cached size/frames string (polled at 2 Hz)
  ULONGLONG last_detail_ms_ = 0;  // last detail recompute (GetTickCount64)
  bool dragging_ = false;        // the strip is being dragged
  POINT drag_off_{};             // cursor-screen - window-origin at drag start
  bool abort_armed_ = false;     // Abort is in its confirm step
  ULONGLONG abort_arm_ms_ = 0;   // when Abort was armed (auto-disarms after 3s)

  RECT stop_rc_{}, pause_rc_{}, abort_rc_{};  // physical px, client coords

  bool frame_up_ = false;             // the frame overlays are shown (border/scrims)
  HWND border_hwnd_ = nullptr;        // red outline around the recorded rect
  std::vector<HWND> scrim_hwnds_;     // outside-rect + other-display dim overlays

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
  winrt::com_ptr<IDWriteTextFormat> label_fmt_;       // centered button label
  winrt::com_ptr<IDWriteTextFormat> btn_lead_fmt_;    // leading label (Finish glyph)
  winrt::com_ptr<IDWriteTextFormat> size_fmt_;  // file-size / frame-count readout
  winrt::com_ptr<IDWriteTextFormat> cd_fmt_;  // big countdown number
};

#endif  // RUNNER_RECORD_CHROME_H_
