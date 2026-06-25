#ifndef RUNNER_CURSOR_IMAGE_H_
#define RUNNER_CURSOR_IMAGE_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <vector>

// The current system cursor as a bitmap, for the overlay's toggleable
// mouse-pointer layer (the freeze frame is captured WITHOUT the cursor; the
// pointer is composited from this). The macOS analogue is ScreenCapturer.cursorPNG.
namespace cursorimg {

struct CursorBitmap {
  std::vector<uint8_t> bgra;  // straight-alpha BGRA8888, top-down, stride=width*4
  uint32_t width = 0;
  uint32_t height = 0;
  int hotspot_x = 0;  // in bitmap pixels
  int hotspot_y = 0;
};

// The current system cursor, or nullopt when hidden / unavailable / a cursor
// (e.g. a monochrome legacy cursor) that does not render with alpha.
std::optional<CursorBitmap> Capture();

}  // namespace cursorimg

#endif  // RUNNER_CURSOR_IMAGE_H_
