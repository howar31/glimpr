#include "cursor_image.h"

#include <cstring>

namespace cursorimg {

std::optional<CursorBitmap> Capture() {
  CURSORINFO ci{};
  ci.cbSize = sizeof(CURSORINFO);
  // Capture the cursor SHAPE even when it is not currently showing: during an
  // active freeze overlay the OS cursor is hidden (ShowCursor(FALSE)), so a
  // re-trigger (layer 2+) would otherwise get no cursor image and the toolbar's
  // cursor-layer toggle would vanish. macOS uses NSCursor.currentSystem, which is
  // visibility-independent. When the cursor is hidden Windows reports a NULL
  // hCursor, so fall back to the default arrow (the shape under the overlay).
  if (!GetCursorInfo(&ci)) return std::nullopt;
  HCURSOR hcur = ci.hCursor ? ci.hCursor : LoadCursorW(nullptr, IDC_ARROW);
  if (!hcur) return std::nullopt;
  ICONINFO ii{};
  if (!GetIconInfo(hcur, &ii)) return std::nullopt;

  // Size from the cursor bitmap: a color cursor's hbmColor carries the size; a
  // mask-only (monochrome) cursor's hbmMask is width x (2*height) (AND over XOR).
  BITMAP bm{};
  uint32_t w = 0, h = 0;
  if (ii.hbmColor) {
    GetObject(ii.hbmColor, sizeof(bm), &bm);
    w = static_cast<uint32_t>(bm.bmWidth);
    h = static_cast<uint32_t>(bm.bmHeight);
  } else if (ii.hbmMask) {
    GetObject(ii.hbmMask, sizeof(bm), &bm);
    w = static_cast<uint32_t>(bm.bmWidth);
    h = static_cast<uint32_t>(bm.bmHeight / 2);
  }
  const int hot_x = static_cast<int>(ii.xHotspot);
  const int hot_y = static_cast<int>(ii.yHotspot);
  if (ii.hbmColor) DeleteObject(ii.hbmColor);
  if (ii.hbmMask) DeleteObject(ii.hbmMask);
  if (w == 0 || h == 0) return std::nullopt;

  // 32bpp top-down DIB; DrawIconEx DI_NORMAL renders colour + mask -> straight
  // alpha for modern colour cursors (the default on Win10/11).
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = static_cast<LONG>(w);
  bi.bmiHeader.biHeight = -static_cast<LONG>(h);  // negative = top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP dib =
      CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);

  std::optional<CursorBitmap> out;
  if (dib && bits) {
    HGDIOBJ old = SelectObject(mem, dib);
    std::memset(bits, 0, static_cast<size_t>(w) * h * 4);  // transparent
    DrawIconEx(mem, 0, 0, hcur, static_cast<int>(w), static_cast<int>(h),
               0, nullptr, DI_NORMAL);
    SelectObject(mem, old);
    GdiFlush();
    CursorBitmap cb;
    cb.width = w;
    cb.height = h;
    cb.hotspot_x = hot_x;
    cb.hotspot_y = hot_y;
    cb.bgra.resize(static_cast<size_t>(w) * h * 4);
    std::memcpy(cb.bgra.data(), bits, cb.bgra.size());
    out = std::move(cb);
  }
  if (dib) DeleteObject(dib);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  return out;
}

}  // namespace cursorimg
