#ifndef RUNNER_PIN_WINDOW_H_
#define RUNNER_PIN_WINDOW_H_

#include <windows.h>

#include <d2d1_1.h>
#include <wincodec.h>
#include <winrt/base.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// A floating, always-on-top reference image ("pin to screen"). Native Win32 +
// Direct2D, mirroring the macOS PinPanel: a transparent halo margin around the
// image, drag anywhere, wheel zoom 25-300%, a 1s-hover reveal of an Aurora vapor
// glow (3 brand-colored Direct2D drop-shadows that drift + breathe) and a glass
// close button, and a right-click menu (Reset Size / Save As / Copy / Close).
// A layered (per-pixel alpha) window updated via UpdateLayeredWindow. Pixel-bulk
// + OS-edge, so native by the split (a Flutter engine per pin would cost ~10-25
// MB each + a cold start; this holds only the decoded bitmap and opens instantly).
class PinWindow {
 public:
  PinWindow();
  ~PinWindow();

  PinWindow(const PinWindow&) = delete;
  PinWindow& operator=(const PinWindow&) = delete;

  // Build + show the pin. [place_logical] is the GLOBAL, top-left-origin LOGICAL
  // rect (pin-in-place over a captured region); nullopt centers the pin on the
  // cursor's monitor at the image's native size. [on_closed] is invoked when the
  // pin closes so the manager can drop it.
  bool Create(const std::string& image_path,
              std::optional<RECT> place_logical,
              std::function<void(PinWindow*)> on_closed);

  HWND hwnd() const { return hwnd_; }

 private:
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM) noexcept;
  LRESULT MessageHandler(HWND, UINT, WPARAM, LPARAM) noexcept;

  bool InitGraphics(const std::wstring& path);  // WIC decode + D2D device
  void Render();                                // draw -> UpdateLayeredWindow
  void SetZoom(double z);                        // re-center + resize + render
  void Reveal(bool on);
  void ShowMenu();
  void SaveAs();
  void CopyToClipboard();
  void ClosePin();

  // Geometry helpers (all in PHYSICAL pixels).
  int MarginPx() const;
  RECT ImageRectInWindow() const;  // the image area inside the window
  RECT CloseButtonRect() const;    // the glass close button (when revealed)

  HWND hwnd_ = nullptr;
  std::function<void(PinWindow*)> on_closed_;

  // Source image: STRAIGHT BGRA (kept for Save As / Copy) + native pixel size.
  std::vector<uint8_t> bgra_;
  uint32_t img_w_ = 0;
  uint32_t img_h_ = 0;
  double monitor_scale_ = 1.0;  // for the logical halo margin + placement
  double zoom_ = 1.0;

  // Window geometry in PHYSICAL pixels (UpdateLayeredWindow manages it).
  int win_x_ = 0;
  int win_y_ = 0;
  int win_w_ = 0;
  int win_h_ = 0;

  bool revealed_ = false;       // hover-reveal target
  float reveal_t_ = 0.0f;        // current reveal fade (0..1)
  bool close_hover_ = false;
  bool tracking_leave_ = false;
  bool dwell_pending_ = false;   // the 1s hover-dwell timer is armed
  double anim_phase_ = 0.0;      // advanced by the reveal animation timer

  bool dragging_ = false;
  POINT drag_offset_{};  // cursor - window origin at drag start

  // Persistent Direct2D device + the image as a device bitmap (reused per frame).
  winrt::com_ptr<IWICImagingFactory> wic_;
  winrt::com_ptr<ID2D1Factory1> factory_;
  winrt::com_ptr<ID2D1Device> device_;
  winrt::com_ptr<ID2D1DeviceContext> dc_;
  winrt::com_ptr<ID2D1Bitmap1> image_bitmap_;
};

// Owns the live pins; a pin removes itself here when closed. Mirrors the macOS
// MainFlutterWindow.pins array. One instance, owned by FlutterWindow.
class PinManager {
 public:
  // Float [image_path] as a pin. [place_logical] = pin-in-place (capture flow
  // with a region rect); nullopt centers (editor / clipboard pins).
  void Pin(const std::string& image_path, std::optional<RECT> place_logical);

 private:
  std::vector<std::unique_ptr<PinWindow>> pins_;
};

#endif  // RUNNER_PIN_WINDOW_H_
